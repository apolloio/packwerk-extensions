# typed: strict
# frozen_string_literal: true

require 'parser/current'

module Packwerk
  module Privacy
    # Resolves which constants are explicitly marked as public via @pack_public YARD annotations
    # within files matching specific patterns.
    class GranularPublicityResolver
      extend T::Sig

      CacheEntry = T.type_alias { { mtime: Time, constants: T::Set[String] } }

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
            constant_name: String,
            patterns: T::Array[String]
          ).returns(T::Boolean)
        end
        def public_constant?(file_path, constant_name, patterns)
          return false if patterns.empty?
          return false unless matches_pattern?(file_path, patterns)

          public_constants = public_constants_for_file(file_path)
          public_constants.include?(constant_name)
        end

        private

        sig { params(file_path: String, patterns: T::Array[String]).returns(T::Boolean) }
        def matches_pattern?(file_path, patterns)
          patterns.any? do |glob|
            expanded_glob = glob.start_with?('/') || glob.start_with?('**/') ? glob : "**/#{glob}"
            Pathname.new(file_path).fnmatch(expanded_glob, File::FNM_EXTGLOB | File::FNM_PATHNAME)
          end
        end

        sig { params(file_path: String).returns(T::Set[String]) }
        def public_constants_for_file(file_path)
          return Set.new unless File.exist?(file_path)

          current_mtime = File.mtime(file_path)
          cached = cache[file_path]

          if cached && cached[:mtime] == current_mtime
            return cached[:constants]
          end

          constants = extract_public_constants(file_path)
          cache[file_path] = { mtime: current_mtime, constants: constants }
          constants
        end

        sig { params(file_path: String).returns(T::Set[String]) }
        def extract_public_constants(file_path)
          source = File.read(file_path)
          buffer = Parser::Source::Buffer.new(file_path)
          buffer.source = source

          parser = Parser::CurrentRuby.new
          ast, comments = parser.parse_with_comments(buffer)

          return Set.new unless ast

          public_comment_lines = find_pack_public_comment_lines(comments)
          return Set.new if public_comment_lines.empty?

          ConstantExtractor.new(public_comment_lines).extract(ast)
        rescue Parser::SyntaxError
          Set.new
        end

        sig { params(comments: T::Array[Parser::Source::Comment]).returns(T::Set[Integer]) }
        def find_pack_public_comment_lines(comments)
          result = Set.new
          comments.each do |comment|
            if comment.text =~ /@pack_public\b/
              result.add(comment.loc.last_line)
            end
          end
          result
        end
      end

      # Extracts fully qualified constant names from AST nodes that follow @pack_public comments
      class ConstantExtractor
        extend T::Sig

        sig { params(public_comment_lines: T::Set[Integer]).void }
        def initialize(public_comment_lines)
          @public_comment_lines = public_comment_lines
          @nesting = T.let([], T::Array[String])
          @public_constants = T.let(Set.new, T::Set[String])
        end

        sig { params(ast: Parser::AST::Node).returns(T::Set[String]) }
        def extract(ast)
          visit(ast)
          @public_constants
        end

        private

        sig { params(node: T.untyped).void }
        def visit(node)
          return unless node.is_a?(Parser::AST::Node)

          case node.type
          when :class, :module
            handle_class_or_module(node)
          when :casgn
            handle_constant_assignment(node)
          else
            node.children.each { |child| visit(child) if child.is_a?(Parser::AST::Node) }
          end
        end

        sig { params(node: Parser::AST::Node).void }
        def handle_class_or_module(node)
          name_node = node.children[0]
          name = extract_const_name(name_node)

          if name && marked_public?(node)
            @public_constants.add(build_fully_qualified_name(name))
          end

          if name
            @nesting.push(name)
            # Skip the name node (index 0) and optionally superclass (index 1 for class)
            body_index = node.type == :class ? 2 : 1
            body = node.children[body_index]
            visit(body)
            @nesting.pop
          else
            node.children.each { |child| visit(child) }
          end
        end

        sig { params(node: Parser::AST::Node).void }
        def handle_constant_assignment(node)
          scope, name, _value = node.children

          return unless name.is_a?(Symbol)
          return unless scope.nil?

          if marked_public?(node)
            @public_constants.add(build_fully_qualified_name(name.to_s))
          end

          node.children.each { |child| visit(child) }
        end

        sig { params(node: Parser::AST::Node).returns(T::Boolean) }
        def marked_public?(node)
          node_line = node.loc.line
          @public_comment_lines.include?(node_line - 1)
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

        sig { params(name: String).returns(String) }
        def build_fully_qualified_name(name)
          if @nesting.empty?
            "::#{name}"
          else
            "::#{@nesting.join('::')}::#{name}"
          end
        end
      end
    end
  end
end
