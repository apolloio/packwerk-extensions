# typed: strict
# frozen_string_literal: true

require 'parser/current'

module Packwerk
  module Privacy
    # Resolves which constants and methods are explicitly marked as public via @pack_public YARD annotations
    # within files matching specific patterns.
    class GranularPublicityResolver
      extend T::Sig

      PublicItems = T.type_alias { { constants: T::Set[String], methods: T::Set[String] } }
      CacheEntry = T.type_alias { { mtime: Time, items: PublicItems } }

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

          public_items = public_items_for_file(file_path)
          public_items[:constants].include?(constant_name)
        end

        sig do
          params(
            file_path: String,
            constant_name: String,
            method_name: String,
            patterns: T::Array[String]
          ).returns(T::Boolean)
        end
        def public_method?(file_path, constant_name, method_name, patterns)
          return false if patterns.empty?
          return false unless matches_pattern?(file_path, patterns)

          public_items = public_items_for_file(file_path)
          # Check for fully qualified method name: "::ClassName.method_name"
          public_items[:methods].include?("#{constant_name}.#{method_name}")
        end

        private

        sig { params(file_path: String, patterns: T::Array[String]).returns(T::Boolean) }
        def matches_pattern?(file_path, patterns)
          patterns.any? do |glob|
            expanded_glob = glob.start_with?('/') || glob.start_with?('**/') ? glob : "**/#{glob}"
            Pathname.new(file_path).fnmatch(expanded_glob, File::FNM_EXTGLOB | File::FNM_PATHNAME)
          end
        end

        sig { params(file_path: String).returns(PublicItems) }
        def public_items_for_file(file_path)
          empty_items = { constants: Set.new, methods: Set.new }
          return empty_items unless File.exist?(file_path)

          current_mtime = File.mtime(file_path)
          cached = cache[file_path]

          if cached && cached[:mtime] == current_mtime
            return cached[:items]
          end

          items = extract_public_items(file_path)
          cache[file_path] = { mtime: current_mtime, items: items }
          items
        end

        sig { params(file_path: String).returns(PublicItems) }
        def extract_public_items(file_path)
          source = File.read(file_path)
          buffer = Parser::Source::Buffer.new(file_path)
          buffer.source = source

          parser = Parser::CurrentRuby.new
          ast, comments = parser.parse_with_comments(buffer)

          empty_items = { constants: Set.new, methods: Set.new }
          return empty_items unless ast

          public_comment_lines = find_pack_public_comment_lines(comments)
          return empty_items if public_comment_lines.empty?

          PublicItemExtractor.new(public_comment_lines).extract(ast)
        rescue Parser::SyntaxError
          { constants: Set.new, methods: Set.new }
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

      # Extracts fully qualified constant names and method names from AST nodes
      # that follow @pack_public comments
      class PublicItemExtractor
        extend T::Sig

        sig { params(public_comment_lines: T::Set[Integer]).void }
        def initialize(public_comment_lines)
          @public_comment_lines = public_comment_lines
          @nesting = T.let([], T::Array[String])
          @public_constants = T.let(Set.new, T::Set[String])
          @public_methods = T.let(Set.new, T::Set[String])
          @sig_blocks = T.let({}, T::Hash[Integer, Integer]) # end_line => start_line
        end

        sig { params(ast: Parser::AST::Node).returns(PublicItems) }
        def extract(ast)
          find_sig_blocks(ast) # First pass: find all sig blocks
          visit(ast)           # Second pass: extract public items
          { constants: @public_constants, methods: @public_methods }
        end

        private

        sig { params(node: T.untyped).void }
        def find_sig_blocks(node)
          return unless node.is_a?(Parser::AST::Node)

          if sig_block?(node)
            start_line = node.loc.line
            end_line = node.loc.last_line
            @sig_blocks[end_line] = start_line
          end

          node.children.each { |child| find_sig_blocks(child) }
        end

        sig { params(node: Parser::AST::Node).returns(T::Boolean) }
        def sig_block?(node)
          return false unless node.type == :block

          receiver_node = node.children[0]
          return false unless receiver_node.is_a?(Parser::AST::Node)
          return false unless receiver_node.type == :send

          _, method_name, * = receiver_node.children
          method_name == :sig
        end

        sig { params(node: T.untyped).void }
        def visit(node)
          return unless node.is_a?(Parser::AST::Node)

          case node.type
          when :class, :module
            handle_class_or_module(node)
          when :casgn
            handle_constant_assignment(node)
          when :defs
            handle_singleton_method(node)
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

        sig { params(node: Parser::AST::Node).void }
        def handle_singleton_method(node)
          receiver, method_name, * = node.children

          return unless method_name.is_a?(Symbol)
          return unless receiver.is_a?(Parser::AST::Node)
          return unless receiver.type == :self

          if marked_public?(node)
            # Build method name as "::ClassName.method_name"
            class_name = build_current_class_name
            @public_methods.add("#{class_name}.#{method_name}")
          end
        end

        sig { params(node: Parser::AST::Node).returns(T::Boolean) }
        def marked_public?(node)
          node_line = node.loc.line

          # Check if @pack_public is directly above
          return true if @public_comment_lines.include?(node_line - 1)

          # Check if there's a sig block above, and @pack_public is above that
          sig_start_line = @sig_blocks[node_line - 1]
          return true if sig_start_line && @public_comment_lines.include?(sig_start_line - 1)

          false
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

        sig { returns(String) }
        def build_current_class_name
          if @nesting.empty?
            '::'
          else
            "::#{@nesting.join('::')}"
          end
        end
      end
    end
  end
end
