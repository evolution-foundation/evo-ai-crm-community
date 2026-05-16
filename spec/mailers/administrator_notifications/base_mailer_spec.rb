RSpec.describe AdministratorNotifications::BaseMailer, type: :mailer do
  describe '#admin_emails' do
    let!(:admin_user) { create(:user, email: 'admin@example.com') }
    let!(:super_admin_user) { create(:user, email: 'super_admin@example.com') }
    let!(:agent_user) { create(:user, email: 'agent@example.com') }
    let!(:admin_role) { create(:role, key: 'administrator') }
    let!(:super_admin_role) { create(:role, key: 'super_admin') }
    let!(:agent_role) { create(:role, key: 'agent') }

    before do
      admin_user.roles << admin_role
      super_admin_user.roles << super_admin_role
      agent_user.roles << agent_role
    end

    it 'returns emails of admin users' do
      mailer_class = described_class.new
      admin_emails = mailer_class.send(:admin_emails)

      expect(admin_emails).to match_array(['admin@example.com', 'super_admin@example.com'])
    end

    it 'does not include agent users' do
      mailer_class = described_class.new
      admin_emails = mailer_class.send(:admin_emails)

      expect(admin_emails).not_to include('agent@example.com')
    end
  end

  describe '#send_notification' do
    let!(:admin_user) { create(:user, email: 'admin@example.com') }
    let!(:admin_role) { create(:role, key: 'administrator') }

    before do
      admin_user.roles << admin_role
      allow(ENV).to receive(:fetch).with('FRONTEND_URL', nil).and_return('http://example.com')
    end

    it 'sends notification to admin emails' do
      mail = described_class.send_notification(
        'Test Subject',
        action_url: 'http://example.com/action',
        meta: { key: 'value' }
      )

      expect(mail.to).to include('admin@example.com')
    end

    it 'includes action URL in action_url variable' do
      mail = described_class.send_notification(
        'Test Subject',
        action_url: 'http://example.com/action'
      )

      expect(mail.body.encoded).to include('http://example.com/action')
    end

    it 'includes meta data' do
      mail = described_class.send_notification(
        'Test Subject',
        action_url: 'http://example.com/action',
        meta: { key: 'value' }
      )

      expect(mail.body.encoded).to include('value')
    end
  end
end
