# typed: true
# frozen_string_literal: true

require 'test_helper'

module Packwerk
  module Privacy
    class MethodCallExtractorTest < Minitest::Test
      extend T::Sig
      include ApplicationFixtureHelper

      setup do
        setup_application_fixture
        MethodCallExtractor.clear_cache!
      end

      teardown do
        teardown_application_fixture
        MethodCallExtractor.clear_cache!
      end

      test 'extracts method name from simple class method call' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            def call
              Foo.bar(1, 2)
            end
          end
        RUBY

        # Line 3, column 4 is where "Foo" starts
        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          3,
          4,
          '::Foo'
        )

        assert_equal 'bar', method_name
      end

      test 'extracts method name from namespaced class method call' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            def call
              ZpRedis::Analyzer.sample_keys(redis, 100)
            end
          end
        RUBY

        # Line 3, column 4 is where "ZpRedis::Analyzer" starts
        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          3,
          4,
          '::ZpRedis::Analyzer'
        )

        assert_equal 'sample_keys', method_name
      end

      test 'returns nil for constant-only reference' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            include Foo
          end
        RUBY

        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          2,
          10,
          '::Foo'
        )

        assert_nil method_name
      end

      test 'returns nil for constant reference in type annotation' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            sig { params(x: Foo).void }
            def call(x)
            end
          end
        RUBY

        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          2,
          16,
          '::Foo'
        )

        assert_nil method_name
      end

      test 'extracts method name with safe navigation operator' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            def call
              Foo&.bar
            end
          end
        RUBY

        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          3,
          4,
          '::Foo'
        )

        assert_equal 'bar', method_name
      end

      test 'extracts method name with block' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            def call
              Foo.each do |item|
                puts item
              end
            end
          end
        RUBY

        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          3,
          4,
          '::Foo'
        )

        assert_equal 'each', method_name
      end

      test 'returns nil for non-existent file' do
        use_template(:minimal)

        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('nonexistent.rb'),
          1,
          0,
          '::Foo'
        )

        assert_nil method_name
      end

      test 'handles syntax errors gracefully' do
        use_template(:minimal)
        write_app_file(['broken.rb'], <<~RUBY)
          class Broken
            def invalid syntax
          end
        RUBY

        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('broken.rb'),
          2,
          4,
          '::Foo'
        )

        assert_nil method_name
      end

      test 'caches AST and invalidates on file change' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            def call
              Foo.bar
            end
          end
        RUBY

        file_path = to_app_path('caller.rb')

        method_name = MethodCallExtractor.extract_method_name(file_path, 3, 4, '::Foo')
        assert_equal 'bar', method_name
        assert MethodCallExtractor.cache.key?(file_path)

        sleep 0.1
        File.write(file_path, <<~RUBY)
          class Caller
            def call
              Foo.baz
            end
          end
        RUBY

        method_name = MethodCallExtractor.extract_method_name(file_path, 3, 4, '::Foo')
        assert_equal 'baz', method_name
      end

      test 'returns nil when constant name does not match receiver' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            def call
              Bar.method_name
            end
          end
        RUBY

        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          3,
          4,
          '::Foo'
        )

        assert_nil method_name
      end

      test 'handles method call on different line than constant' do
        use_template(:minimal)
        write_app_file(['caller.rb'], <<~RUBY)
          class Caller
            def call
              ZpRedis::Analyzer
                .sample_keys(redis)
            end
          end
        RUBY

        # The constant reference is on line 3, but we need to find the send node
        method_name = MethodCallExtractor.extract_method_name(
          to_app_path('caller.rb'),
          3,
          4,
          '::ZpRedis::Analyzer'
        )

        assert_equal 'sample_keys', method_name
      end
    end
  end
end
