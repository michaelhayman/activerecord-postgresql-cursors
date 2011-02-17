
module ActiveRecord

  # Exception raised when database cursors aren't supported, which they
  # absolutely should be in our app.
  class CursorsNotSupported < ActiveRecordError; end

  module CursorExtensions
    extend ActiveSupport::Concern

    included do
      alias_method_chain :find, :cursors
    end

    # Override ActiveRecord::Base#find to allow for cursors in
    # PostgreSQL. To use a cursor, set the first argument of
    # find to :cursor. A PostgreSQLCursor object will be returned,
    # which can then be used as an Enumerable to loop through the
    # results.
    #
    # By default, cursor names are generated automatically using
    # "cursor_#{rand}", where rand is a big ol' random number that
    # is pretty unlikely to clash if you're using nested cursors.
    # Alternatively, you can supply a specific cursor name by
    # supplying a :cursor_name option.
    def find_with_cursors(*args)
      if args.first.to_s == 'cursor'
        options = args.extract_options!
        cursor_name = options.delete(:cursor_name)
        find_cursor(cursor_name, options)
      else
        find_without_cursors(*args)
      end
    end

    def cursor(*args)
      find_with_cursors('cursor', *args)
    end

    private
    # Find method for using cursors. This works just like the regular
    # ActiveRecord::Base#find_every method, except it returns a
    # PostgreSQLCursor object that can be used to loop through records.
      def find_cursor(cursor_name, options)
        unless connection.is_a? ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
          raise CursorsNotSupported, "#{connection.class} doesn't support cursors"
        end

        if eager_loading?
          including = (@eager_load_values + @includes_values).uniq
          join_dependency = ActiveRecord::Associations::ClassMethods::JoinDependency.new(@klass, including, nil)
          join_relation = construct_relation_for_association_find(join_dependency)

          ActiveRecord::PostgreSQLCursor.new(self, cursor_name, join_relation, join_dependency)
        else
          relation = apply_finder_options(options)

          ActiveRecord::PostgreSQLCursor.new(self, cursor_name, relation)
        end
      end
  end

  module Associations
    module ClassMethods
      class JoinDependency
        # Extra method we can use to clear out a couple of things in
        # JoinDependency so we can use some of the methods for our
        # cursors code.
        def clear_with_cursor
          @reflections            = []
          @base_records_hash      = {}
          @base_records_in_order  = []
        end
      end
    end
  end

  # PostgreSQLCursor is an Enumerable class so you can use each, map,
  # any? and all of those nice Enumerable methods.
  #
  # At the moment, cursors aren't scrollable and are fetch forward-only
  # and read-only.
  #
  # This class isn't really meant to be used outside of the
  # ActiveRecord::Base#find method.
  class PostgreSQLCursor
    include Enumerable

    attr_accessor :cursor_name

    # To create a new PostgreSQLCursor, you'll need the ActiveRecord
    # model you're creating the cursor for so we can reference it,
    # the SQL query you wish to cursify (see our custom
    # ActiveRecord::Base#find_cursor method) and the JoinDependency
    # used to create the query if necessary so we can figure out
    # associations.
    def initialize model, cursor_name, relation, join_dependency = nil
      @model = model
      @cursor_name = if cursor_name
        @model.connection.quote_table_name(cursor_name.gsub(/"/, '\"'))
      end
      @relation = relation
      @join_dependency = join_dependency
      @options = {}
    end

    def inspect
      %{#<ActiveRecord::PostgreSQLCursor cursor_name: "#{cursor_name}", query: "#{@relation.to_sql}>"}
    end

    # Calls block once for each record in the cursor, passing that
    # record as a parameter.
    def each
      @model.transaction do
        begin
          declare_cursor
          if @join_dependency
            rows = Array.new
            last_id = nil
            while row = fetch_forward
              current_id = row[@join_dependency.join_base.aliased_primary_key]
              last_id ||= current_id
              if last_id == current_id
                rows << row
                last_id = current_id
              else
                yield @join_dependency.instantiate(rows).first
                @join_dependency.clear_with_cursor
                rows = [ row ]
              end
              last_id = current_id
            end

            if !rows.empty?
              yield @join_dependency.instantiate(rows).first
            end
          else
            while row = fetch_forward
              yield row
            end
          end
        ensure
          close_cursor
        end
      end
      nil
    end

    private
      def cursor_name
        @cursor_name ||= "cursor_#{(rand * 1000000).ceil}"
      end

      def fetch_forward #:nodoc:
        @model.find_by_sql(%{FETCH FORWARD FROM #{cursor_name}}).first
      end

      def declare_cursor #:nodoc:
        @model.connection.execute(%{DECLARE #{cursor_name} CURSOR FOR #{@relation.to_sql}})
      end

      def close_cursor #:nodoc:
        @model.connection.execute(%{CLOSE #{cursor_name}})
      end
  end
end

class ActiveRecord::Relation
  include ActiveRecord::CursorExtensions
end

class ActiveRecord::Base
  class << self
    delegate :cursor, :to => :scoped
  end
end