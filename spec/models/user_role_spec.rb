RSpec.describe UserRole, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
    it { should belong_to(:role) }
    it { should belong_to(:granted_by).class_name('User').optional }
  end

  describe 'validations' do
    subject { build(:user_role) }

    it { should validate_presence_of(:user) }
    it { should validate_presence_of(:role) }
  end
end
