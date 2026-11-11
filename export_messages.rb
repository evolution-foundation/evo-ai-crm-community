# frozen_string_literal: true

# Script to export conversation history for a specific contact and date range
# Usage: bundle exec rails runner export_messages.rb

phone = "+55 75 9831-5298"
digits = phone.gsub(/[^0-9]/, '') # => "557598315298"
contact = Contact.find_by("phone_number = ? OR phone_number = ? OR phone_number LIKE ?", phone, "+#{digits}", "%#{digits}")

if !contact
  puts "❌ Contact not found for phone: #{phone}"
  puts "\nTry searching for these close matches:"
  Contact.where("phone_number LIKE ?", "%#{digits[-8..]}").limit(5).each do |c|
    puts " - Name: #{c.name}, Phone: #{c.phone_number}"
  end
  exit
end

# Date range (inclusive in local time zone / server zone)
start_date = Time.zone.parse("2026-04-30").beginning_of_day
end_date = Time.zone.parse("2026-05-10").end_of_day

puts "=================================================="
puts "👤 Contact: #{contact.name}"
puts "📞 Phone: #{contact.phone_number}"
puts "📅 Date Range: #{start_date.strftime('%d/%m/%Y %H:%M')} to #{end_date.strftime('%d/%m/%Y %H:%M')}"
puts "=================================================="

# Create export folder in public/uploads to hold attachments
export_dir = Rails.root.join("public", "uploads", "export_#{contact.id}")
FileUtils.mkdir_p(export_dir) unless Dir.exist?(export_dir)

messages = contact.conversations.flat_map do |conv|
  conv.messages.where(created_at: start_date..end_date)
end.sort_by(&:created_at)

if messages.empty?
  puts "ℹ️ No messages found in this date range."
else
  messages.each do |msg|
    sender = case msg.message_type
             when "incoming" then "CLIENTE"
             when "outgoing" then "ATENDENTE"
             when "activity" then "ATIVIDADE/SISTEMA"
             when "template" then "TEMPLATE"
             else msg.message_type.upcase
             end

    # Time display
    time = msg.created_at.strftime("%d/%m/%Y %H:%M:%S")

    # If it is a private note or activity, show it
    note_prefix = msg.private? ? " [NOTA PRIVADA]" : ""

    puts "\n[#{time}] #{sender}#{note_prefix}:"
    if msg.content.present?
      puts "   #{msg.content}"
    end

    next unless msg.attachments.any?

    puts "   📎 Attachments:"
    msg.attachments.each do |attachment|
      if attachment.file.attached?
        blob = attachment.file.blob
        export_path = File.join(export_dir, blob.filename.to_s)
        
        # Download and save the file to the export folder
        File.open(export_path, 'wb') do |f|
          f.write(attachment.file.download)
        end

        relative_url = "/public/uploads/export_#{contact.id}/#{blob.filename}"
        puts "     - [#{attachment.file_type}] #{blob.filename} (#{blob.byte_size} bytes)"
        puts "       Local VPS Path: ~/kaiabi-atendimento/evo-ai-crm-community/public/uploads/export_#{contact.id}/#{blob.filename}"
        puts "       Download URL: #{relative_url}"
      else
        puts "     - [#{attachment.file_type}] External Link: #{attachment.external_url}"
      end
    end
  end
  puts "\n=================================================="
  puts "✅ Export finished! File attachments were copied to:"
  puts "   ~/kaiabi-atendimento/evo-ai-crm-community/public/uploads/export_#{contact.id}/"
  puts "=================================================="
end
