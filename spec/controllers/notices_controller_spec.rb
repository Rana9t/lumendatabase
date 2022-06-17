require 'rails_helper'

describe NoticesController do
  context '#show' do
    it 'finds the notice by ID' do
      notice = Notice.new
      expect(Notice).to receive(:find_by).with(id: '42').and_return(notice)

      get :show, params: { id: 42 }

      expect(assigns(:notice)).to eq notice
    end

    context 'as HTML' do
      it 'renders the show template' do
        stub_find_notice

        get :show, params: { id: 1 }

        expect(response).to be_successful
        expect(response).to render_template(:show)
      end

      it 'renders the rescinded template if the notice is rescinded' do
        stub_find_notice(build(:dmca, rescinded: true))

        get :show, params: { id: 1 }

        expect(response).to be_successful
        expect(response).to render_template(:rescinded)
      end

      it 'renders the unavailable template if the notice is spam' do
        stub_find_notice(build(:dmca, spam: true))

        get :show, params: { id: 1 }

        expect(response.status).to eq(404)
        expect(response).to render_template('error_pages/404_unavailable')
      end

      it 'renders the unavailable template if the notice is unpublished' do
        stub_find_notice(build(:dmca, published: false))

        get :show, params: { id: 1 }

        expect(response.status).to eq(404)
        expect(response).to render_template('error_pages/404_unavailable')
      end

      it 'renders the hidden template if the notice is hidden' do
        stub_find_notice(build(:dmca, hidden: true))

        get :show, params: { id: 1 }

        expect(response.status).to eq(404)
        expect(response).to render_template('error_pages/404_hidden')
      end
    end

    context 'as JSON' do
      Notice.type_models.each do |model_class|
        it "returns a serialized notice for #{model_class}" do
          notice = stub_find_notice(model_class.new)

          serializer_class = notice.model_serializer || NoticeSerializer
          serialized = serializer_class.new(notice)

          expect(serializer_class).to receive(:new)
            .with(notice)
            .and_return(serialized)

          get :show, params: { id: 1, format: :json }

          json = JSON.parse(response.body)[model_class.to_s.tableize.singularize]
          expect(json).to have_key('id').with_value(notice.id)
          expect(json).to have_key('title').with_value(notice.title)
          expect(json).to have_key('sender_name')
        end
      end

      it "returns id, title and 'Notice Rescinded' as body for a rescinded notice" do
        notice = build(:dmca, rescinded: true)
        stub_find_notice(notice)

        get :show, params: { id: 1, format: :json }

        json = JSON.parse(response.body)['dmca']
        expect(json).to have_key('id').with_value(notice.id)
        expect(json).to have_key('title').with_value(notice.title)
        expect(json).to have_key('body').with_value('Notice Rescinded')
      end

      it 'returns original URLs for a Notice if you are a researcher' do
        user = create(:user, roles: [Role.researcher])
        params = {
          notice: {
            title: 'A title',
            type: 'DMCA',
            subject: 'Infringement Notfication via Blogger Complaint',
            date_sent: '2013-05-22',
            date_received: '2013-05-23',
            works_attributes: [
              {
                description: 'The Avengers',
                infringing_urls_attributes: [
                  { url: 'http://youtube.com/bad_url_1' },
                  { url: 'http://youtube.com/bad_url_2' },
                  { url: 'http://youtube.com/bad_url_3' }
                ]
              }
            ],
            entity_notice_roles_attributes: [
              {
                name: 'recipient',
                entity_attributes: {
                  name: 'Google',
                  kind: 'organization',
                  address_line_1: '1600 Amphitheatre Parkway',
                  city: 'Mountain View',
                  state: 'CA',
                  zip: '94043',
                  country_code: 'US'
                }
              },
              {
                name: 'sender',
                entity_attributes: {
                  name: 'Joe Lawyer',
                  kind: 'individual',
                  address_line_1: '1234 Anystreet St.',
                  city: 'Anytown',
                  state: 'CA',
                  zip: '94044',
                  country_code: 'US'
                }
              }
            ]
          }
        }

        notice = Notice.new(params[:notice])
        notice.save
        stub_find_notice(notice)

        get :show, params: { id: 1, format: :json }

        json = JSON.parse(response.body)['dmca']['works'][0]['infringing_urls'][0]
        expect(json).to have_key('count')
        expect(json).to have_key('domain')

        get :show, params: {
          id: 1, authentication_token: user.authentication_token, format: :json
        }

        json = JSON.parse(response.body)["dmca"]["works"][0]["infringing_urls"][0]
        expect(json).to have_key('url')
        expect(json).not_to have_key('url_original')
      end
    end

    context 'by notice_viewer' do
      let(:notice) { build(:dmca) }
      let(:user) do
        build(
          :user,
          :notice_viewer
        )
      end

      it 'increases the notice counter for the user when the viewing limit is set and viewing html' do
        expect(Notice).to receive(:find_by).with(id: '42').and_return(notice)

        user.full_notice_views_limit = 1
        allow(controller).to receive(:current_user).and_return(user)

        get :show, params: { id: 42 }

        expect(user.viewed_notices).to eq 1
      end

      it "won't increase the notice counter for the user when the viewing limit is set and viewing json" do
        expect(Notice).to receive(:find_by).with(id: '42').and_return(notice)

        user.full_notice_views_limit = 1
        allow(controller).to receive(:current_user).and_return(user)

        get :show, params: { id: 42, format: :json }

        expect(user.viewed_notices).to eq 0
      end

      it "won't increase the notice counter for the user when the viewing limit is nil or 0" do
        expect(Notice).to receive(:find_by).with(id: '42').exactly(2).times.and_return(notice)

        user.full_notice_views_limit = nil
        allow(controller).to receive(:current_user).and_return(user)

        get :show, params: { id: 42, format: :json }

        expect(user.viewed_notices).to eq 0

        user.full_notice_views_limit = 0

        get :show, params: { id: 42, format: :json }

        expect(user.viewed_notices).to eq 0
      end

      it 'increases the notice counter for the user when the viewing limit is set until the limit is reached' do
        expect(Notice).to receive(:find_by).with(id: '42').exactly(3).times.and_return(notice)

        user.full_notice_views_limit = 2
        allow(controller).to receive(:current_user).and_return(user)

        get :show, params: { id: 42 }

        expect(user.viewed_notices).to eq 1

        get :show, params: { id: 42 }

        expect(user.viewed_notices).to eq 2

        get :show, params: { id: 42 }

        expect(user.viewed_notices).to eq 2
      end
    end

    context 'updates stats' do
      let(:notice) { build(:dmca) }
      let(:notice_viewer_user) do
        build(
          :user,
          :notice_viewer
        )
      end

      it 'increases the notice views counter for an anonymous user' do
        notice.views_overall = 0
        notice.views_by_notice_viewer = 0

        expect(Notice).to receive(:find_by).twice.with(id: '42').and_return(notice)

        allow(controller).to receive(:current_user).and_return(nil)

        get :show, params: { id: 42 }
        get :show, params: { id: 42 }

        expect(notice.views_overall).to eq 2
        expect(notice.views_by_notice_viewer).to eq 0
      end

      it 'increases the notice notice_viewer views counter for a user with the notice_viewer role' do
        notice.views_overall = 50
        notice.views_by_notice_viewer = 5

        expect(Notice).to receive(:find_by).exactly(3).times.with(id: '42').and_return(notice)

        allow(controller).to receive(:current_user).and_return(notice_viewer_user)

        get :show, params: { id: 42 }
        get :show, params: { id: 42 }
        get :show, params: { id: 42 }

        expect(notice.views_overall).to eq 53
        expect(notice.views_by_notice_viewer).to eq 8
      end

      it 'increases the token url temp views counter' do
        expect(Notice).to receive(:find_by).exactly(6).times.with(id: '42').and_return(notice)

        token_url = TokenUrl.create!(
          email: 'test_user@lumendatabase.org',
          valid_forever: false,
          notice: notice
        )

        allow(controller).to receive(:current_user).and_return(notice_viewer_user)

        get :show, params: { id: 42, access_token: token_url.token }
        get :show, params: { id: 42, access_token: token_url.token }
        get :show, params: { id: 42, access_token: token_url.token }

        token_url.reload
        expect(token_url.views).to eq 3

        token_url = TokenUrl.create!(
          user: notice_viewer_user,
          email: 'test_user@lumendatabase.org',
          valid_forever: true,
          notice: notice
        )

        get :show, params: { id: 42, access_token: token_url.token }
        get :show, params: { id: 42, access_token: token_url.token }
        get :show, params: { id: 42, access_token: token_url.token }

        token_url.reload
        expect(token_url.views).to eq 3
      end
    end

    def stub_find_notice(notice = nil)
      notice ||= Notice.new
      notice.tap { |n| allow(Notice).to receive(:find_by).and_return(n) }
    end
  end

  context '#create' do
    before do
      @fake_notice = double('Notice').as_null_object
      @notice_params = ActiveSupport::HashWithIndifferentAccess.new(title: 'A title')
    end

    def make_allowances
      allow(subject).to receive(:authorized_to_create?).and_return true
      allow(NoticeBuilder).to receive(:new).and_return @fake_notice
      allow(@fake_notice).to receive(:id).and_return 1
      allow(@fake_notice).to receive(:errors).and_return []
    end

    context 'format-independent logic' do
      it 'initializes a DMCA by default from params' do
        make_allowances

        expect(NoticeBuilder).to receive(:new)
          .with(DMCA, @notice_params, anything)

        post :create, params: { notice: @notice_params }
      end

      it 'uses the type param to instantiate the correct class' do
        make_allowances

        expect(NoticeBuilder).to receive(:new)
          .with(Trademark, @notice_params, anything)

        post :create, params: {
          notice: @notice_params.merge(type: 'trademark')
        }
      end

      it 'defaults to DMCA if the type is missing or invalid' do
        invalid_types = ['', 'FlimFlam', 'Object', 'User', 'Hash']

        make_allowances
        expect(NoticeBuilder).to receive(:new)
          .exactly(5).times
          .with(DMCA, @notice_params, anything)
          .and_return(@fake_notice)

        invalid_types.each do |invalid_type|
          post :create, params: {
            notice: @notice_params.merge(type: invalid_type)
          }
        end
      end
    end

    context 'as HTML' do
      it 'renders the new template when unsuccessful' do
        make_allowances
        allow(@fake_notice).to receive(:valid?).and_return(false)

        post_create

        expect(assigns(:notice)).to eq @fake_notice
        expect(response).to render_template(:new)
      end
    end

    context 'as JSON' do
      before do
        @ability = Object.new
        @ability.extend(CanCan::Ability)
        @ability.can(:submit, Notice)
        allow(controller).to receive(:current_ability) { @ability }
      end

      it 'returns unauthorized if one cannot submit' do
        # Don't stub authorized_to_create? here -- we want to be implementation-
        # independent.
        @ability.cannot(:submit, Notice)
        response_body = { documentation_link: Rails.configuration.x.api_documentation_link }.to_json
        post_create :json

        expect(response.status).to eq 401
        expect(response.body).to eq response_body
      end

      it 'returns a proper Location header when saved successfully' do
        notice = create(:dmca)
        allow(subject).to receive(:authorized_to_create?).and_return true
        allow(NoticeBuilder).to receive_message_chain(:new, :build)
                            .and_return notice

        post_create :json

        expect(response).to be_successful
        expect(response.headers['Location']).to eq notice_url(notice)
      end

      it 'returns a useful status code when there are errors' do
        make_allowances
        allow(@fake_notice).to receive(:valid?).and_return(false)
        allow(@fake_notice).to receive(:errors).and_return(['bruh'])

        post_create :json

        expect(response).to be_unprocessable
      end

      it 'includes any errors in the response' do
        make_allowances
        allow(@fake_notice).to receive(:valid?).and_return(false)
        allow(@fake_notice).to receive(:errors).and_return(['bruh'])

        post_create :json

        json = JSON.parse(response.body)
        expect(json).to have_key('notices').with_value(['bruh'])
      end
    end

    private

    def post_create(format = :html)
      post :create, params: { notice: { title: 'A title' }, format: format }
    end

    def mock_errors(model, field_errors = {})
      ActiveModel::Errors.new(model).tap do |errors|
        field_errors.each do |field, message|
          errors.add(field, message)
        end
      end
    end
  end
end
