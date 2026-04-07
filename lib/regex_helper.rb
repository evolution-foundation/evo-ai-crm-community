module RegexHelper
  # user https://rubular.com/ to quickly validate your regex

  # the following regext needs atleast one character which should be
  # valid unicode letter, unicode number, underscore, hyphen
  # shouldn't start with a underscore or hyphen
  UNICODE_CHARACTER_NUMBER_HYPHEN_UNDERSCORE = Regexp.new('\A[\p{L}\p{N}]+[\p{L}\p{N}_-]+\Z')
  
  # allows unicode letters, numbers, literal spaces (not tabs/newlines), hyphens, underscores
  # must start and end with letter or number (spaces normalized before validation)
  UNICODE_CHARACTER_NUMBER_SPACE_HYPHEN_UNDERSCORE = Regexp.new('\A[\p{L}\p{N}]+([ _-]*[\p{L}\p{N}]+)*\Z')
  
  MENTION_REGEX = Regexp.new('\[(@[\w_. ]+)\]\(mention://(?:user|team)/\d+/(.*?)+\)')

  TWILIO_CHANNEL_SMS_REGEX = Regexp.new('^\+\d{1,15}\z')
  TWILIO_CHANNEL_WHATSAPP_REGEX = Regexp.new('^whatsapp:\+\d{1,15}\z')
  BSUID_REGEX = /\A[A-Z]{2}\.[a-zA-Z0-9]+\z/
  WHATSAPP_CHANNEL_REGEX = Regexp.new('\A(?:\+?\d{1,15}|\+?\d+@lid|[A-Z]{2}\.[a-zA-Z0-9]+)\z')
end
