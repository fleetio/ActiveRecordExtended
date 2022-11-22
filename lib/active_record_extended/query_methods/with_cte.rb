# frozen_string_literal: true

module ActiveRecordExtended
  module QueryMethods
    module WithCTE
      class WithCTE
        include ActiveRecordExtended::Utilities::Support
        include Enumerable
        extend  Forwardable

        def_delegators :@with_values, :empty?, :blank?, :present?
        attr_reader :with_values, :with_keys, :materialized_keys, :not_materialized_keys

        # @param [ActiveRecord::Relation] scope
        def initialize(scope)
          @scope = scope
          reset!
        end

        # @return [Enumerable] Returns the order for which CTE's were imported as.
        def each
          return to_enum(:each) unless block_given?

          with_keys.each do |key|
            yield(key, with_values[key])
          end
        end
        alias each_pair each

        # @param [Hash, WithCTE] value
        def with_values=(value)
          reset!
          pipe_cte_with!(value)
        end

        # @return [Boolean]
        def materialized_key?(key)
          materialized_keys.include?(key.to_sym)
        end

        # @return [Boolean]
        def not_materialized_key?(key)
          not_materialized_keys.include?(key.to_sym)
        end

        # @param [Hash, WithCTE] value
        def pipe_cte_with!(value)
          return if value.nil? || value.empty?

          value.each_pair do |name, expression|
            sym_name = name.to_sym
            next if with_values.key?(sym_name)

            # Ensure we follow FIFO pattern.
            # If the parent has similar CTE alias keys, we want to favor the parent's expressions over its children's.
            if expression.is_a?(ActiveRecord::Relation) && expression.with_values?
              pipe_cte_with!(expression.cte)
              expression.cte.reset!
            end

            @with_keys            |= [sym_name]
            @with_values[sym_name] = expression
          end

          value.reset! if value.is_a?(WithCTE)
        end

        def reset!
          @with_keys   = []
          @with_values = {}
          @materialized_keys = []
          @not_materialized_keys = []
        end
      end

      class WithChain
        # @param [ActiveRecord::Relation] scope
        def initialize(scope)
          @scope       = scope
          @scope.cte ||= WithCTE.new(scope)
        end

        # @param [Hash, WithCTE] args
        def recursive(args)
          @scope.tap do |scope|
            scope.recursive_value = true
            scope.cte.pipe_cte_with!(args)
          end
        end

        # @param [Hash, WithCTE] args
        def materialized(args)
          @scope.tap do |scope|
            args.each_pair do |name, _expression|
              sym_name = name.to_sym
              raise ArgumentError.new("CTE already set as not_materialized") if scope.cte.not_materialized_key?(sym_name)

              scope.cte.materialized_keys << sym_name
            end
            scope.cte.pipe_cte_with!(args)
          end
        end

        # @param [Hash, WithCTE] args
        def not_materialized(args)
          @scope.tap do |scope|
            args.each_pair do |name, _expression|
              sym_name = name.to_sym
              raise ArgumentError.new("CTE already set as materialized") if scope.cte.materialized_key?(sym_name)

              scope.cte.not_materialized_keys << sym_name
            end
            scope.cte.pipe_cte_with!(args)
          end
        end
      end

      # @return [WithCTE]
      def cte
        @values[:cte]
      end

      # @param [WithCTE] cte
      def cte=(cte)
        raise TypeError.new("Must be a WithCTE class type") unless cte.is_a?(WithCTE)

        @values[:cte] = cte
      end

      # @return [Boolean]
      def with_values?
        !(cte.nil? || cte.empty?)
      end

      # @param [Hash, WithCTE] values
      def with_values=(values)
        cte.with_values = values
      end

      # @param [Boolean] value
      def recursive_value=(value)
        raise ImmutableRelation if @loaded

        @values[:recursive] = value
      end

      # @return [Boolean]
      def recursive_value?
        !(!@values[:recursive])
      end

      # @param [Hash, WithCTE] opts
      def with(opts = :chain, *rest)
        return WithChain.new(spawn) if opts == :chain

        opts.blank? ? self : spawn.with!(opts, *rest)
      end

      # @param [Hash, WithCTE] opts
      def with!(opts = :chain, *_rest)
        return WithChain.new(self) if opts == :chain

        tap do |scope|
          scope.cte ||= WithCTE.new(self)
          scope.cte.pipe_cte_with!(opts)
        end
      end

      def build_with(arel)
        return unless with_values?

        cte_statements = cte.map do |name, expression|
          grouped_expression = cte.generate_grouping(expression)
          cte_name           = cte.to_arel_sql(cte.double_quote(name.to_s))

          grouped_expression = add_materialized_modifier(grouped_expression, cte, name)

          Arel::Nodes::As.new(cte_name, grouped_expression)
        end

        if recursive_value?
          arel.with(:recursive, cte_statements)
        else
          arel.with(cte_statements)
        end
      end

      private

      def add_materialized_modifier(expression, cte, name)
        expression = Arel::Nodes::SqlLiteral.new("MATERIALIZED #{expression.to_sql}") if cte.materialized_key?(name)
        expression = Arel::Nodes::SqlLiteral.new("NOT MATERIALIZED #{expression.to_sql}") if cte.not_materialized_key?(name)
        expression
      end
    end
  end
end

ActiveRecord::Relation.prepend(ActiveRecordExtended::QueryMethods::WithCTE)
