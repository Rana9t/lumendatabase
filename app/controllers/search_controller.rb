# This class abstracts common functionality of Notices::SearchController and
# Entities::SearchController. It is not meant to be used on its own. It should
# be subclassed, and subclasses must define the following:
# - EACH_SERIALIZER
# - URL_ROOT
# - SEARCHED_MODEL
# - item_searcher
# - set_model_specific_variables
# They may also define html_responder.
class SearchController < ApplicationController
  before_action :set_model_specific_variables
  before_action :prevent_impossible_pagination
  before_action :restrict_deep_pagination

  layout 'search'

  EACH_SERIALIZER = nil
  URL_ROOT = nil

  def index
    if request.format.html? && current_user.nil? && !Rails.env.test?
      permitted = false

      if session[:captcha_permission]
        time_permission = session[:captcha_permission]
        permitted = true if time_permission > Time.now
      end

      LumenLogger.log_metrics('VIEWED_SEARCH_CAPTCHA')

      unless permitted
        redirect_to(captcha_gateway_index_path(destination: CGI.escape(request.original_url))) and return
      end
    end

    @searcher = item_searcher
    @searchdata = @searcher.search
    @wrapped_instances = wrap_instances

    LumenLogger.log_metrics('SEARCHED', search_details: meta_hash_for(@searchdata).except(:facets))

    respond_to do |format|
      format.html { html_responder }
      format.json { json_renderer }
    end
  end

  private

  def html_responder; end

  def item_searcher; end

  def json_renderer
    # The self.class incantation is necessary to make instances look up their
    # subclass overrides to these constants, rather than pulling in the
    # original definition.
    render(
      json: {
        self.class::URL_ROOT => @wrapped_instances.map { |instance| self.class::EACH_SERIALIZER.new(instance) },
        meta: meta_hash_for(@searchdata)
      }
    )
  end

  # Enrich the activerecord object with search-related metadata for display.
  # Return the enriched instance (or nil, if none was found).
  def augment_instance(instance)
    return unless instance.present?

    result = @searchdata.select { |datum| datum[:_id] == instance.id.to_s }.first

    class << instance
      attr_accessor :_score, :highlight
    end

    instance._score = result[:_score]

    highlights = result[:highlight].presence || []
    instance.highlight = highlights.map { |h| h[1] }.flatten

    instance
  end

  def sort_by(sort_by_param)
    ResultOrdering.define(sort_by_param, @model_class).sort_by
  end

  def wrap_instances
    # #records fetches the database instances while maintaining the search
    # response ordering.
    # Note that the search definition above is lazy; this is the first line
    # where anything with Elasticsearch actually gets executed.
    instances = @searchdata.records
    instances.map { |r| augment_instance(r) }
  end

  # Elasticsearch cannot return more than 20_000 results in production (2000
  # pages at 10 results per page).
  def prevent_impossible_pagination
    return if num_results < 20_001

    render 'shared/_error',
           status: :not_found,
           locals: {
             message: 'Lumen cannot display beyond the 20,000th result. ' \
                      'Try a more specific query.'
           }
  end

  # Deep pagination is expensive for the CPU, so don't let anonymous users
  # do it.
  def restrict_deep_pagination
    return if pagination_allowed?

    render 'shared/_error',
           status: :unauthorized,
           locals: {
             message: 'You must be logged in to see past the first 100 ' \
                      'results. ' \
                      '<a href="https://lumendatabase.org/pages/researchers#key">Request ' \
                      'a research account key</a>.'.html_safe
           }
  end

  def pagination_allowed?
    [user_signed_in?,
     num_results < 101,
     request.format.json? && num_results < 20_001].any?
  end

  def num_results
    params[:page].to_i * (params[:per_page] || 10 ).to_i
  end

  def meta_hash_for(results)
    %i[
      current_page next_page offset per_page
      previous_page total_entries total_pages
    ].each_with_object(query_meta(results)) do |attribute, memo|
      begin
        memo[attribute] = results.send(attribute)
      rescue
        memo[attribute] = nil
      end
    end
  end

  def query_meta(results)
    {
      query: {
        term: params[:term]
      }.merge(facet_query_meta(results) || {}),
      facets: results.response.aggregations
    }
  end

  def facet_query_meta(results)
    results.response.aggregations && results.response.aggregations.keys.each_with_object({}) do |facet, memo|
      memo[facet.to_sym] = params[facet.to_sym] if params[facet.to_sym].present?
    end
  end

  def set_model_specific_variables; end
end
