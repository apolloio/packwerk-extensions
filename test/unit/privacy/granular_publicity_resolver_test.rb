# typed: true
# frozen_string_literal: true

require 'test_helper'

module Packwerk
  module Privacy
    class GranularPublicityResolverTest < Minitest::Test
      extend T::Sig
      include ApplicationFixtureHelper

      setup do
        setup_application_fixture
        GranularPublicityResolver.clear_cache!
      end

      teardown do
        teardown_application_fixture
        GranularPublicityResolver.clear_cache!
      end

      test 'returns false when patterns array is empty' do
        use_template(:minimal)
        write_app_file(['test.rb'], <<~RUBY)
          # @pack_public
          class MyClass
          end
        RUBY

        refute GranularPublicityResolver.public_constant?(
          to_app_path('test.rb'),
          '::MyClass',
          []
        )
      end

      test 'returns false when file does not match pattern' do
        use_template(:minimal)
        write_app_file(['app/models/test.rb'], <<~RUBY)
          # @pack_public
          class MyClass
          end
        RUBY

        refute GranularPublicityResolver.public_constant?(
          to_app_path('app/models/test.rb'),
          '::MyClass',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when class has @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/my_service.rb'], <<~RUBY)
          # @pack_public
          class MyService
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/my_service.rb'),
          '::MyService',
          ['app/services/**/*.rb']
        )
      end

      test 'returns false when class lacks @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/my_service.rb'], <<~RUBY)
          class MyService
          end
        RUBY

        refute GranularPublicityResolver.public_constant?(
          to_app_path('app/services/my_service.rb'),
          '::MyService',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when module has @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/my_module.rb'], <<~RUBY)
          # @pack_public
          module MyModule
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/my_module.rb'),
          '::MyModule',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when constant assignment has @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/constants.rb'], <<~RUBY)
          module Constants
            # @pack_public
            DEFAULT_VALUE = 42
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/constants.rb'),
          '::Constants::DEFAULT_VALUE',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true for nested class with @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/billing/charge.rb'], <<~RUBY)
          module Billing
            # @pack_public
            class Charge
              def execute
              end
            end
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/billing/charge.rb'),
          '::Billing::Charge',
          ['app/services/**/*.rb']
        )
      end

      test 'returns false for nested class without @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/billing/helper.rb'], <<~RUBY)
          module Billing
            class Helper
            end
          end
        RUBY

        refute GranularPublicityResolver.public_constant?(
          to_app_path('app/services/billing/helper.rb'),
          '::Billing::Helper',
          ['app/services/**/*.rb']
        )
      end

      test 'handles multiple @pack_public annotations in same file' do
        use_template(:minimal)
        write_app_file(['app/services/billing.rb'], <<~RUBY)
          module Billing
            # @pack_public
            class Charge
            end

            class InternalHelper
            end

            # @pack_public
            DEFAULT_CURRENCY = 'USD'
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/billing.rb'),
          '::Billing::Charge',
          ['app/services/**/*.rb']
        )

        refute GranularPublicityResolver.public_constant?(
          to_app_path('app/services/billing.rb'),
          '::Billing::InternalHelper',
          ['app/services/**/*.rb']
        )

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/billing.rb'),
          '::Billing::DEFAULT_CURRENCY',
          ['app/services/**/*.rb']
        )
      end

      test 'handles deeply nested modules' do
        use_template(:minimal)
        write_app_file(['app/services/a/b/c.rb'], <<~RUBY)
          module A
            module B
              # @pack_public
              class C
              end
            end
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/a/b/c.rb'),
          '::A::B::C',
          ['app/services/**/*.rb']
        )
      end

      test 'caches results and invalidates on file change' do
        use_template(:minimal)
        write_app_file(['app/services/cached.rb'], <<~RUBY)
          # @pack_public
          class Cached
          end
        RUBY

        file_path = to_app_path('app/services/cached.rb')

        assert GranularPublicityResolver.public_constant?(
          file_path,
          '::Cached',
          ['app/services/**/*.rb']
        )

        assert GranularPublicityResolver.cache.key?(file_path)

        sleep 0.1
        File.write(file_path, <<~RUBY)
          class Cached
          end
        RUBY

        refute GranularPublicityResolver.public_constant?(
          file_path,
          '::Cached',
          ['app/services/**/*.rb']
        )
      end

      test 'handles syntax errors gracefully' do
        use_template(:minimal)
        write_app_file(['app/services/broken.rb'], <<~RUBY)
          # @pack_public
          class Broken
            def invalid syntax here
          end
        RUBY

        refute GranularPublicityResolver.public_constant?(
          to_app_path('app/services/broken.rb'),
          '::Broken',
          ['app/services/**/*.rb']
        )
      end

      test 'returns false for non-existent file' do
        use_template(:minimal)

        refute GranularPublicityResolver.public_constant?(
          to_app_path('app/services/nonexistent.rb'),
          '::SomeClass',
          ['app/services/**/*.rb']
        )
      end

      test 'matches multiple patterns' do
        use_template(:minimal)
        write_app_file(['app/interactors/my_interactor.rb'], <<~RUBY)
          # @pack_public
          class MyInteractor
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/interactors/my_interactor.rb'),
          '::MyInteractor',
          ['app/services/**/*.rb', 'app/interactors/**/*.rb']
        )
      end

      test 'handles @pack_public with additional text on same line' do
        use_template(:minimal)
        write_app_file(['app/services/documented.rb'], <<~RUBY)
          # @pack_public This class is part of the public API
          class Documented
          end
        RUBY

        assert GranularPublicityResolver.public_constant?(
          to_app_path('app/services/documented.rb'),
          '::Documented',
          ['app/services/**/*.rb']
        )
      end

      test 'ignores @pack_public in string literals' do
        use_template(:minimal)
        write_app_file(['app/services/string_test.rb'], <<~RUBY)
          class StringTest
            COMMENT = "# @pack_public"
          end
        RUBY

        refute GranularPublicityResolver.public_constant?(
          to_app_path('app/services/string_test.rb'),
          '::StringTest',
          ['app/services/**/*.rb']
        )
      end

      # Method-level @pack_public tests

      test 'returns true when singleton method has @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            # @pack_public
            def self.sample_keys(redis, count)
              # implementation
            end
          end
        RUBY

        assert GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'sample_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when @pack_public is above a Sorbet sig block' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            extend T::Sig

            # Sample top memory consuming keys
            # @pack_public
            sig { params(redis: Redis, sample_size: Integer).returns(T::Hash[String, Integer]) }
            def self.sample_keys(redis, sample_size)
              # implementation
            end
          end
        RUBY

        assert GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'sample_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when @pack_public is directly above method with sig below' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            extend T::Sig

            sig { params(redis: Redis).returns(T::Hash[String, Integer]) }
            # @pack_public
            def self.sample_keys(redis)
              # implementation
            end
          end
        RUBY

        assert GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'sample_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when @pack_public is above multi-line Sorbet sig block' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            extend T::Sig

            # @pack_public
            sig do
              params(
                redis: Redis,
                sample_size: Integer,
                take: Integer
              ).returns(T::Hash[String, Integer])
            end
            def self.sample_top_memory_consuming_keys(redis, sample_size, take: 50)
              # implementation
            end
          end
        RUBY

        assert GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'sample_top_memory_consuming_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when @pack_public is in middle of YARD comment block' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            extend T::Sig

            # Sample top memory consuming keys
            # @pack_public
            # @param redis [Redis]
            # @param sample_size [Integer]
            sig { params(redis: Redis, sample_size: Integer).returns(T::Hash[String, Integer]) }
            def self.sample_keys(redis, sample_size)
              # implementation
            end
          end
        RUBY

        assert GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'sample_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true when @pack_public is in middle of YARD block with multi-line sig' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            extend T::Sig

            # Sample top memory consuming keys
            # @pack_public
            # @param redis [Redis]
            # @param sample_size [Integer]
            # @param take [Integer]
            sig do
              params(redis: Redis, sample_size: Integer, take: Integer).returns(T::Hash[String, Integer])
            end
            def self.sample_top_memory_consuming_keys(redis, sample_size, take: 50)
              # implementation
            end
          end
        RUBY

        assert GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'sample_top_memory_consuming_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'returns false when @pack_public is in unrelated comment block above' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            extend T::Sig

            # @pack_public - this is for something else

            # This method is not public
            # @param redis [Redis]
            sig { params(redis: Redis).returns(T::Hash[String, Integer]) }
            def self.sample_keys(redis)
              # implementation
            end
          end
        RUBY

        refute GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'sample_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'returns false when singleton method lacks @pack_public annotation' do
        use_template(:minimal)
        write_app_file(['app/services/analyzer.rb'], <<~RUBY)
          class Analyzer
            def self.internal_helper
              # implementation
            end
          end
        RUBY

        refute GranularPublicityResolver.public_method?(
          to_app_path('app/services/analyzer.rb'),
          '::Analyzer',
          'internal_helper',
          ['app/services/**/*.rb']
        )
      end

      test 'returns true for annotated method in nested module' do
        use_template(:minimal)
        write_app_file(['app/services/zp_redis/analyzer.rb'], <<~RUBY)
          module ZpRedis
            class Analyzer
              # @pack_public
              def self.sample_top_memory_consuming_keys(redis, sample_size)
                # implementation
              end
            end
          end
        RUBY

        assert GranularPublicityResolver.public_method?(
          to_app_path('app/services/zp_redis/analyzer.rb'),
          '::ZpRedis::Analyzer',
          'sample_top_memory_consuming_keys',
          ['app/services/**/*.rb']
        )
      end

      test 'handles multiple annotated methods in same class' do
        use_template(:minimal)
        write_app_file(['app/services/multi.rb'], <<~RUBY)
          class Multi
            # @pack_public
            def self.public_one
            end

            def self.private_one
            end

            # @pack_public
            def self.public_two
            end
          end
        RUBY

        file_path = to_app_path('app/services/multi.rb')
        patterns = ['app/services/**/*.rb']

        assert GranularPublicityResolver.public_method?(file_path, '::Multi', 'public_one', patterns)
        refute GranularPublicityResolver.public_method?(file_path, '::Multi', 'private_one', patterns)
        assert GranularPublicityResolver.public_method?(file_path, '::Multi', 'public_two', patterns)
      end

      test 'returns false when patterns array is empty for methods' do
        use_template(:minimal)
        write_app_file(['test.rb'], <<~RUBY)
          class MyClass
            # @pack_public
            def self.my_method
            end
          end
        RUBY

        refute GranularPublicityResolver.public_method?(
          to_app_path('test.rb'),
          '::MyClass',
          'my_method',
          []
        )
      end

      test 'returns false when file does not match pattern for methods' do
        use_template(:minimal)
        write_app_file(['app/models/test.rb'], <<~RUBY)
          class MyClass
            # @pack_public
            def self.my_method
            end
          end
        RUBY

        refute GranularPublicityResolver.public_method?(
          to_app_path('app/models/test.rb'),
          '::MyClass',
          'my_method',
          ['app/services/**/*.rb']
        )
      end

      test 'does not treat instance methods as public' do
        use_template(:minimal)
        write_app_file(['app/services/instance.rb'], <<~RUBY)
          class Instance
            # @pack_public
            def instance_method
            end
          end
        RUBY

        refute GranularPublicityResolver.public_method?(
          to_app_path('app/services/instance.rb'),
          '::Instance',
          'instance_method',
          ['app/services/**/*.rb']
        )
      end

      test 'cache includes both constants and methods' do
        use_template(:minimal)
        write_app_file(['app/services/mixed.rb'], <<~RUBY)
          # @pack_public
          class Mixed
            # @pack_public
            def self.api_method
            end
          end
        RUBY

        file_path = to_app_path('app/services/mixed.rb')
        patterns = ['app/services/**/*.rb']

        assert GranularPublicityResolver.public_constant?(file_path, '::Mixed', patterns)
        assert GranularPublicityResolver.public_method?(file_path, '::Mixed', 'api_method', patterns)

        # Verify cache structure
        assert GranularPublicityResolver.cache.key?(file_path)
        cached = GranularPublicityResolver.cache[file_path]
        assert cached[:items][:constants].include?('::Mixed')
        assert cached[:items][:methods].include?('::Mixed.api_method')
      end

      test 'invalidates cache on file change for methods' do
        use_template(:minimal)
        write_app_file(['app/services/cached_method.rb'], <<~RUBY)
          class CachedMethod
            # @pack_public
            def self.api_method
            end
          end
        RUBY

        file_path = to_app_path('app/services/cached_method.rb')
        patterns = ['app/services/**/*.rb']

        assert GranularPublicityResolver.public_method?(file_path, '::CachedMethod', 'api_method', patterns)

        sleep 0.1
        File.write(file_path, <<~RUBY)
          class CachedMethod
            def self.api_method
            end
          end
        RUBY

        refute GranularPublicityResolver.public_method?(file_path, '::CachedMethod', 'api_method', patterns)
      end
    end
  end
end
