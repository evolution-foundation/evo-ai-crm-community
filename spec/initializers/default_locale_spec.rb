# frozen_string_literal: true

require 'rails_helper'

# CRM-608: DEFAULT_LOCALE used to reach only the around_action in SwitchLocale, which never
# covers anything rendered from rescue_from. config/initializers/languages.rb now also feeds
# I18n.default_locale from it, which is the value those handlers actually read.
RSpec.describe 'config/initializers/languages.rb default locale' do
  # Re-runs the initializer against a throwaway config, so the booted app is left alone.
  def default_locale_for(env_value)
    previous = ENV.fetch('DEFAULT_LOCALE', nil)
    ENV['DEFAULT_LOCALE'] = env_value
    config = ActiveSupport::OrderedOptions.new
    allow(Rails).to receive(:configuration).and_return(ActiveSupport::OrderedOptions.new.tap { |c| c.i18n = config })
    # silence_warnings: re-running the file reassigns the frozen LANGUAGES_CONFIG to an equal hash.
    silence_warnings { load Rails.root.join('config/initializers/languages.rb').to_s }
    config.default_locale
  ensure
    previous.nil? ? ENV.delete('DEFAULT_LOCALE') : ENV['DEFAULT_LOCALE'] = previous
  end

  it 'takes the installation language from DEFAULT_LOCALE' do
    expect(default_locale_for('pt_BR')).to eq(:pt_BR)
  end

  it 'leaves the Rails default in place when DEFAULT_LOCALE is unset' do
    expect(default_locale_for(nil)).to be_nil
  end

  it 'leaves the Rails default in place when DEFAULT_LOCALE is blank' do
    expect(default_locale_for('')).to be_nil
  end

  it 'refuses a language the installation does not enable, instead of serving missing translations' do
    allow(Rails.logger).to receive(:warn)

    expect(default_locale_for('tlh')).to be_nil
    expect(Rails.logger).to have_received(:warn).with(/tlh is not an enabled language/)
  end
end
