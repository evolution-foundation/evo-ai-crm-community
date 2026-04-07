class Api::V1::Contacts::NotesController < Api::V1::Contacts::BaseController
  before_action :note, except: [:index, :create]

  def index
    notes = @contact.notes.latest.includes(:user)
    render json: notes.as_json(
      only: %i[id content created_at updated_at contact_id user_id],
      include: { user: { only: %i[id name email] } }
    ), status: :ok
  end

  def show
    render json: @note.as_json(
      only: %i[id content created_at updated_at contact_id user_id],
      include: { user: { only: %i[id name email] } }
    ), status: :ok
  end

  def create
    note = @contact.notes.create!(note_params)
    render json: note.as_json(
      only: %i[id content created_at updated_at contact_id user_id],
      include: { user: { only: %i[id name email] } }
    ), status: :created
  end

  def update
    @note.update!(note_params)
    render json: @note.as_json(
      only: %i[id content created_at updated_at contact_id user_id],
      include: { user: { only: %i[id name email] } }
    ), status: :ok
  end

  def destroy
    @note.destroy!
    head :ok
  end

  private

  def note
    @note ||= @contact.notes.includes(:user).find(params[:id])
  end

  def note_params
    params.require(:note).permit(:content).merge({ contact_id: @contact.id, user_id: Current.user.id })
  end
end
