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
          return empty_items unless comments_contain_pack_public?(comments)

          PublicItemExtractor.new(comments).extract(ast)
        rescue Parser::SyntaxError
          { constants: Set.new, methods: Set.new }
        end

        sig { params(comments: T::Array[Parser::Source::Comment]).returns(T::Boolean) }
        def comments_contain_pack_public?(comments)
          comments.any? { |comment| comment.text =~ /@pack_public\b/ }
        end
      end

      # Extracts fully qualified constant names and method names from AST nodes
      # that follow @pack_public comments
      class PublicItemExtractor
        extend T::Sig

        sig { params(comments: T::Array[Parser::Source::Comment]).void }
        def initialize(comments)
          @comment_by_line = T.let(build_comment_index(comments), T::Hash[Integer, Parser::Source::Comment])
          @nesting = T.let([], T::Array[String])
          @public_constants = T.let(Set.new, T::Set[String])
          @public_methods = T.let(Set.new, T::Set[String])
          @sig_blocks = T.let({}, T::Hash[Integer, Integer]) # end_line => start_line
          @in_singleton_class = T.let(false, T::Boolean)
          @in_public_enum = T.let(false, T::Boolean)
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
          when :sclass
            handle_sclass(node)
          when :def
            handle_instance_method_in_singleton(node) if @in_singleton_class
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

            # If this is a public T::Enum class, propagate publicity to enum members
            old_in_public_enum = @in_public_enum
            if node.type == :class && marked_public?(node)
              superclass_name = extract_const_name(node.children[1])
              @in_public_enum = true if superclass_name == 'T::Enum'
            end

            # Skip the name node (index 0) and optionally superclass (index 1 for class)
            body_index = node.type == :class ? 2 : 1
            body = node.children[body_index]
            visit(body)
            @in_public_enum = old_in_public_enum
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

          if marked_public?(node) || @in_public_enum
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

        sig { params(node: Parser::AST::Node).void }
        def handle_sclass(node)
          receiver = node.children[0]

          # Only handle `class << self`, not `class << SomeObject`
          return unless receiver.is_a?(Parser::AST::Node) && receiver.type == :self

          old_value = @in_singleton_class
          @in_singleton_class = true

          # Visit the body of the singleton class
          body = node.children[1]
          visit(body) if body

          @in_singleton_class = old_value
        end

        sig { params(node: Parser::AST::Node).void }
        def handle_instance_method_in_singleton(node)
          method_name = node.children[0]
          return unless method_name.is_a?(Symbol)

          if marked_public?(node)
            class_name = build_current_class_name
            @public_methods.add("#{class_name}.#{method_name}")
          end
        end

        sig { params(node: Parser::AST::Node).returns(T::Boolean) }
        def marked_public?(node)
          target_line = node.loc.line

          # If there's a sig block above, start from above the sig
          sig_start_line = @sig_blocks[target_line - 1]
          check_from_line = sig_start_line ? sig_start_line - 1 : target_line - 1

          # Scan backwards through contiguous comment lines
          comment_block_contains_pack_public?(check_from_line)
        end

        sig { params(start_line: Integer).returns(T::Boolean) }
        def comment_block_contains_pack_public?(start_line)
          current_line = start_line

          # Walk backwards through contiguous comment lines
          while @comment_by_line[current_line]
            comment = T.must(@comment_by_line[current_line])
            return true if comment.text =~ /@pack_public\b/

            current_line -= 1
          end

          false
        end

        sig do
          params(comments: T::Array[Parser::Source::Comment]).returns(T::Hash[Integer, Parser::Source::Comment])
        end
        def build_comment_index(comments)
          comments.each_with_object({}) do |comment, index|
            index[comment.loc.last_line] = comment
          end
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
