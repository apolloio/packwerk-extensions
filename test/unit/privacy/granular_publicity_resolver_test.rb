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
    end
  end
end
