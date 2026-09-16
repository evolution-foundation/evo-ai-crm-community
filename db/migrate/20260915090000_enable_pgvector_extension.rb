class EnablePgvectorExtension < ActiveRecord::Migration[7.0]
  def up
    enable_extension 'vector' unless extension_enabled?('vector')
  end

  def down
    disable_extension 'vector'
  end
end
