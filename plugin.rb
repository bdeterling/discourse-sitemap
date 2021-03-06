# frozen_string_literal: true

# name: discourse-sitemap
# about: Generate XML sitemap for your Discourse forum.
# version: 1.2
# authors: DiscourseHosting.com, vinothkannans
# url: https://github.com/discourse/discourse-sitemap

PLUGIN_NAME = "discourse-sitemap".freeze

enabled_site_setting :sitemap_enabled

after_initialize do

  module ::DiscourseSitemap
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseSitemap
    end
  end

  require_dependency "application_controller"

  class DiscourseSitemap::SitemapController < ::ApplicationController
    layout false
    skip_before_action :preload_json, :check_xhr

    def topics_query(since = nil)
      category_ids = Category.where(read_restricted: false)
        .where.not(slug: skip_categories).pluck(:id)
      query = Topic.where(category_id: category_ids, visible: true)
      if since
        query = query.where('last_posted_at > ?', since)
        query = query.order(last_posted_at: :desc)
      else
        query = query.order(last_posted_at: :asc)
      end
      query
    end

    def topics_query_by_page(index)
      offset = (index - 1) * sitemap_size
      topics_query.limit(sitemap_size).offset(offset)
    end

    def index
      raise ActionController::RoutingError.new('Not Found') unless SiteSetting.sitemap_enabled
      prepend_view_path "plugins/discourse-sitemap/app/views/"

      # 1 hour cache just in case new pages are added
      @output = Rails.cache.fetch("sitemap/index/v6/#{sitemap_size}", expires_in: 1.hour) do
        count = topics_query.count
        @size = count / sitemap_size
        @size += 1 if count % sitemap_size > 0
        @lastmod = {}

        1.upto(@size) do |i|
          @lastmod[i] = last_posted_at(i).xmlschema
          Rails.cache.delete("sitemap/#{i}")
        end

        @lastmod['recent'] = last_posted_at.xmlschema
        render_to_string :index, content_type: 'text/xml; charset=UTF-8'
      end

      render plain: @output, content_type: 'text/xml; charset=UTF-8'
    end

    def default
      raise ActionController::RoutingError.new('Not Found') unless SiteSetting.sitemap_enabled
      prepend_view_path "plugins/discourse-sitemap/app/views/"

      page = Integer(params[:page])
      sitemap(page)
    end

    def recent
      raise ActionController::RoutingError.new('Not Found') unless SiteSetting.sitemap_enabled
      prepend_view_path "plugins/discourse-sitemap/app/views/"

      @output = Rails.cache.fetch("sitemap/recent/#{last_posted_at.to_i}", expires_in: 1.hour) do
        @topics = Array.new
        topics_query(3.days.ago).limit(sitemap_size).pluck(:id, :slug, :last_posted_at, :updated_at, :posts_count).each do |t|
          t[2] = t[3] if t[2].nil?
          @topics.push t
        end
        render :default, content_type: 'text/xml; charset=UTF-8'
      end
      render plain: @output, content_type: 'text/xml; charset=UTF-8' unless performed?
      @output
    end

    def sitemap(page)
      @output = Rails.cache.fetch("sitemap/#{page}/#{sitemap_size}", expires_in: 24.hours) do
        @topics = Array.new
        topics_query_by_page(page).pluck(:id, :slug, :last_posted_at, :updated_at).each do |t|
          t[2] = t[3] if t[2].nil?
          @topics.push t
        end
        render :default, content_type: 'text/xml; charset=UTF-8'
      end
      render plain: @output, content_type: 'text/xml; charset=UTF-8' unless performed?
      @output
    end

    def news
      raise ActionController::RoutingError.new('Not Found') unless SiteSetting.sitemap_enabled
      prepend_view_path "plugins/discourse-sitemap/app/views/"

      @output = Rails.cache.fetch("sitemap/news", expires_in: 5.minutes) do
        dlocale = SiteSetting.default_locale.downcase
        @locale = dlocale.gsub(/_.*/, '')
        @locale = dlocale.sub('_', '-') if @locale === "zh"
        @topics = topics_query(72.hours.ago).pluck(:id, :title, :slug, :created_at)
        render :news, content_type: 'text/xml; charset=UTF-8'
      end
      render plain: @output, content_type: 'text/xml; charset=UTF-8' unless performed?
    end

    private

    def last_posted_at(page = nil)
      query = page.present? ? topics_query_by_page(page) : topics_query
      query.maximum(:last_posted_at) || query.maximum(:updated_at) || 3.days.ago
    end

    def sitemap_size
      @sitemap_size ||= SiteSetting.sitemap_topics_per_page
    end

    def skip_categories
      @skip_categories ||= (SiteSetting.sitemap_skip_categories||'').split(',')
    end
  end

  Discourse::Application.routes.prepend do
    mount ::DiscourseSitemap::Engine, at: "/"
  end

  DiscourseSitemap::Engine.routes.draw do
    get "sitemap.xml" => "sitemap#index"
    get "news.xml" => "sitemap#news"
    get "sitemap_recent.xml" => "sitemap#recent"
    get "sitemap_:page.xml" => "sitemap#default", page: /[1-9][0-9]*/
  end

end
