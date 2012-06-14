require 'upsert/buffer/pg_connection/column_definition'

class Upsert
  class Buffer
    class PG_Connection < Buffer
      attr_reader :db_function_name

      def compose(targets)
        target = targets.first
        unless created_db_function?
          create_db_function target
        end
        hsh = target.to_hash
        ordered_args = column_definitions.map do |c|
          if hsh.has_key? c.name
            hsh[c.name]
          else
            nil
          end
        end
        %{ SELECT #{db_function_name}(#{quote_values(ordered_args)}) }
      end

      def execute(sql)
        connection.exec sql
      end

      def max_length
        INFINITY
      end

      def max_targets
        1
      end

      include Quoter
      
      def quote_ident(k)
        SINGLE_QUOTE + connection.quote_ident(k) + SINGLE_QUOTE
      end
      
      # FIXME escape_bytea with (v, k = nil)
      def quote_value(v)
        case v
        when NilClass
          'NULL'
        when Symbol
          quote_value v.to_s
        when String
          SINGLE_QUOTE + connection.escape_string(v) + SINGLE_QUOTE
        when Time, DateTime
          SINGLE_QUOTE + v.strftime(ISO8601_DATETIME) + SINGLE_QUOTE
        when Date
          SINGLE_QUOTE + v.strftime(ISO8601_DATE) + SINGLE_QUOTE
        else
          v
        end
      end
      
      def column_definitions
        @column_definitions ||= ColumnDefinition.all(connection, table_name)
      end
      
      private
      
      def created_db_function?
        !!@created_db_function_query
      end
      
      def create_db_function(example_row)
        @db_function_name = "pg_temp.merge_#{table_name}_#{Kernel.rand(1e11)}"
        execute <<-EOS
CREATE FUNCTION #{db_function_name}(#{column_definitions.map { |c| "#{c.name}_input #{c.sql_type} DEFAULT #{c.default || 'NULL'}" }.join(',') }) RETURNS VOID AS
$$
BEGIN
    LOOP
        -- first try to update the key
        UPDATE #{table_name} SET #{column_definitions.map { |c| "#{c.name} = #{c.name}_input" }.join(',')} WHERE #{example_row.selector.keys.map { |k| "#{k} = #{k}_input" }.join(' AND ') };
        IF found THEN
            RETURN;
        END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
            INSERT INTO #{table_name}(#{column_definitions.map { |c| c.name }.join(',')}) VALUES (#{column_definitions.map { |c| "#{c.name}_input" }.join(',')});
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$
LANGUAGE plpgsql;
EOS
        @created_db_function_query = true
      end
    end
  end
end
