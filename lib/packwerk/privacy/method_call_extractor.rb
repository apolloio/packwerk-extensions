# typed: strict
# frozen_string_literal: true

require 'parser/current'

module Packwerk
  module Privacy
    # Extracts method names from method calls at a specific source location.
    # Used to determine if a reference like `Foo.bar` is calling a specific method.
    class MethodCallExtractor
      extend T::Sig

      CacheEntry = T.type_alias { { mtime: Time, ast: T.nilable(Parser::AST::Node) } }

      @cache = T.let({}, T::Hash[String, CacheEntry])

      class << self
        extend T::Sig

        sig { returns(T::Hash[String, CacheEntry]) }
        attr_reader :cache

        sig { void }
        def clear_cache!
          @cache = {}
        end

        sig do
          params(
            file_path: String,
            line: Integer,
            column: Integer,
            constant_name: String
          ).returns(T.nilable(String))
        end
        def extract_method_name(file_path, line, column, constant_name)
          return nil unless File.exist?(file_path)

          ast = ast_for_file(file_path)
          return nil unless ast

          node = find_node_at_location(ast, line, column)
          return nil unless node

          extract_method_from_send_node(node, constant_name)
        end

        private

        sig { params(file_path: String).returns(T.nilable(Parser::AST::Node)) }
        def ast_for_file(file_path)
          current_mtime = File.mtime(file_path)
          cached = cache[file_path]

          if cached && cached[:mtime] == current_mtime
            return cached[:ast]
          end

          source = File.read(file_path)
          buffer = Parser::Source::Buffer.new(file_path)
          buffer.source = source

          parser = Parser::CurrentRuby.new
          ast, _comments = parser.parse_with_comments(buffer)

          cache[file_path] = { mtime: current_mtime, ast: ast }
          ast
        rescue Parser::SyntaxError
          cache[file_path] = { mtime: current_mtime, ast: nil }
          nil
        end

        sig do
          params(
            node: T.untyped,
            line: Integer,
            column: Integer
          ).returns(T.nilable(Parser::AST::Node))
        end
        def find_node_at_location(node, line, column)
          return nil unless node.is_a?(Parser::AST::Node)
          return nil unless node.loc

          # Check if this node contains the target location
          node_loc = node.loc
          return nil unless node_loc.expression

          expr = node_loc.expression
          return nil unless location_in_range?(line, column, expr)

          # For send nodes, check if it matches our target location
          if node.type == :send || node.type == :csend
            # The constant reference location points to the receiver
            # Check if this send node's receiver matches the location
            receiver = node.children[0]
            if receiver.is_a?(Parser::AST::Node) && receiver.loc&.expression
              recv_expr = receiver.loc.expression
              if recv_expr.line == line && recv_expr.column == column
                return node
              end
            end
          end

          # Recursively search children for a better match
          node.children.each do |child|
            result = find_node_at_location(child, line, column)
            return result if result
          end

          nil
        end

        sig { params(line: Integer, column: Integer, range: Parser::Source::Range).returns(T::Boolean) }
        def location_in_range?(line, column, range)
          return false if line < range.first_line || line > range.last_line

          if line == range.first_line && line == range.last_line
            column >= range.column && column < range.last_column
          elsif line == range.first_line
            column >= range.column
          elsif line == range.last_line
            column < range.last_column
          else
            true
          end
        end

        sig do
          params(
            node: Parser::AST::Node,
            constant_name: String
          ).returns(T.nilable(String))
        end
        def extract_method_from_send_node(node, constant_name)
          return nil unless node.type == :send || node.type == :csend

          receiver, method_name, * = node.children
          return nil unless method_name.is_a?(Symbol)
          return nil unless receiver.is_a?(Parser::AST::Node)

          # Verify the receiver matches the constant we're looking for
          receiver_name = extract_const_name(receiver)
          return nil unless receiver_name

          # Match the constant (handle both with and without leading ::)
          normalized_constant = constant_name.delete_prefix('::')
          normalized_receiver = receiver_name.delete_prefix('::')

          return nil unless normalized_constant == normalized_receiver

          method_name.to_s
        end

        sig { params(node: T.untyped).returns(T.nilable(String)) }
        def extract_const_name(node)
          return nil unless node.is_a?(Parser::AST::Node)

          case node.type
          when :const
            scope, name = node.children
            if scope.nil?
              name.to_s
            else
              scope_name = extract_const_name(scope)
              scope_name ? "#{scope_name}::#{name}" : name.to_s
            end
          else
            nil
          end
        end
      end
    end
  end
end
