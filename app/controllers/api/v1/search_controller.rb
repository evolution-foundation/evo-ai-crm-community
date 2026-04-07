class Api::V1::SearchController < Api::V1::BaseController
  def index
    @result = search('all')
  end

  def conversations
    @result = search('Conversation')
  end

  def contacts
    @result = search('Contact')
  end

  def messages
    @result = search('Message')
  end


  private

  def search(search_type)
    SearchService.new(
      current_user: Current.user,
      search_type: search_type,
      params: params
    ).perform
  end
end
