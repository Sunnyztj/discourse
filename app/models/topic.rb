# == Schema Information
#
# Table name: topics
#
#  id                      :integer          not null, primary key
#  title                   :string(255)      not null
#  last_posted_at          :datetime
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  views                   :integer          default(0), not null
#  posts_count             :integer          default(0), not null
#  user_id                 :integer          not null
#  last_post_user_id       :integer          not null
#  reply_count             :integer          default(0), not null
#  featured_user1_id       :integer
#  featured_user2_id       :integer
#  featured_user3_id       :integer
#  avg_time                :integer
#  deleted_at              :datetime
#  highest_post_number     :integer          default(0), not null
#  image_url               :string(255)
#  off_topic_count         :integer          default(0), not null
#  like_count              :integer          default(0), not null
#  incoming_link_count     :integer          default(0), not null
#  bookmark_count          :integer          default(0), not null
#  star_count              :integer          default(0), not null
#  category_id             :integer
#  visible                 :boolean          default(TRUE), not null
#  moderator_posts_count   :integer          default(0), not null
#  closed                  :boolean          default(FALSE), not null
#  archived                :boolean          default(FALSE), not null
#  bumped_at               :datetime         not null
#  has_best_of             :boolean          default(FALSE), not null
#  meta_data               :hstore
#  vote_count              :integer          default(0), not null
#  archetype               :string(255)      default("regular"), not null
#  featured_user4_id       :integer
#  notify_moderators_count :integer          default(0), not null
#  spam_count              :integer          default(0), not null
#  illegal_count           :integer          default(0), not null
#  inappropriate_count     :integer          default(0), not null
#  pinned_at               :datetime
#  score                   :float
#  percent_rank            :float            default(1.0), not null
#  notify_user_count       :integer          default(0), not null
#  subtype                 :string(255)
#  slug                    :string(255)
#  auto_close_at           :datetime
#  auto_close_user_id      :integer
#
# Indexes
#
#  idx_topics_user_id_deleted_at     (user_id)
#  index_forum_threads_on_bumped_at  (bumped_at)
#

require_dependency 'slug'
require_dependency 'avatar_lookup'
require_dependency 'topic_view'
require_dependency 'rate_limiter'
require_dependency 'text_sentinel'
require_dependency 'text_cleaner'
require_dependency 'trashable'

class Topic < ActiveRecord::Base
  include ActionView::Helpers
  include RateLimiter::OnCreateRecord
  include Trashable

  def self.max_sort_order
    2**31 - 1
  end

  def self.featured_users_count
    4
  end

  versioned if: :new_version_required?


  def trash!
    super
    update_flagged_posts_count
  end

  def recover!
    super
    update_flagged_posts_count
  end

  rate_limit :default_rate_limiter
  rate_limit :limit_topics_per_day
  rate_limit :limit_private_messages_per_day

  before_validation :sanitize_title

  validates :title, :presence => true,
                    :length => {  :in => SiteSetting.topic_title_length,
                                  :allow_blank => true },
                    :quality_title => { :unless => :private_message? },
                    :unique_among  => { :unless => Proc.new { |t| (SiteSetting.allow_duplicate_topic_titles? || t.private_message?) },
                                        :message => :has_already_been_used,
                                        :allow_blank => true,
                                        :case_sensitive => false,
                                        :collection => Proc.new{ Topic.listable_topics } }

  after_validation do
    self.title = TextCleaner.clean_title(TextSentinel.title_sentinel(title).text) if errors[:title].empty?
  end

  serialize :meta_data, ActiveRecord::Coders::Hstore

  belongs_to :category
  has_many :posts
  has_many :topic_allowed_users
  has_many :topic_allowed_groups

  has_many :allowed_group_users, through: :allowed_groups, source: :users
  has_many :allowed_groups, through: :topic_allowed_groups, source: :group
  has_many :allowed_users, through: :topic_allowed_users, source: :user

  has_one :hot_topic
  belongs_to :user
  belongs_to :last_poster, class_name: 'User', foreign_key: :last_post_user_id
  belongs_to :featured_user1, class_name: 'User', foreign_key: :featured_user1_id
  belongs_to :featured_user2, class_name: 'User', foreign_key: :featured_user2_id
  belongs_to :featured_user3, class_name: 'User', foreign_key: :featured_user3_id
  belongs_to :featured_user4, class_name: 'User', foreign_key: :featured_user4_id
  belongs_to :auto_close_user, class_name: 'User', foreign_key: :auto_close_user_id

  has_many :topic_users
  has_many :topic_links
  has_many :topic_invites
  has_many :invites, through: :topic_invites, source: :invite

  # When we want to temporarily attach some data to a forum topic (usually before serialization)
  attr_accessor :user_data
  attr_accessor :posters  # TODO: can replace with posters_summary once we remove old list code
  attr_accessor :topic_list

  # The regular order
  scope :topic_list_order, lambda { order('topics.bumped_at desc') }

  # Return private message topics
  scope :private_messages, lambda {
    where(archetype: Archetype::private_message)
  }

  scope :listable_topics, lambda { where('topics.archetype <> ?', [Archetype.private_message]) }

  scope :by_newest, order('topics.created_at desc, topics.id desc')

  # Helps us limit how many favorites can be made in a day
  class FavoriteLimiter < RateLimiter
    def initialize(user)
      super(user, "favorited:#{Date.today.to_s}", SiteSetting.max_favorites_per_day, 1.day.to_i)
    end
  end

  before_create do
    self.bumped_at ||= Time.now
    self.last_post_user_id ||= user_id
    if !@ignore_category_auto_close and self.category and self.category.auto_close_days and self.auto_close_at.nil?
      self.auto_close_at = self.category.auto_close_days.days.from_now
      self.auto_close_user = (self.user.staff? ? self.user : Discourse.system_user)
    end
  end

  after_create do
    changed_to_category(category)
    TopicUser.change(user_id, id,
                     notification_level: TopicUser.notification_levels[:watching],
                     notifications_reason_id: TopicUser.notification_reasons[:created_topic])
    if archetype == Archetype.private_message
      DraftSequence.next!(user, Draft::NEW_PRIVATE_MESSAGE)
    else
      DraftSequence.next!(user, Draft::NEW_TOPIC)
    end
  end

  before_save do
    if (auto_close_at_changed? and !auto_close_at_was.nil?) or (auto_close_user_id_changed? and auto_close_at)
      Jobs.cancel_scheduled_job(:close_topic, {topic_id: id})
      true
    end
  end

  after_save do
    if auto_close_at and (auto_close_at_changed? or auto_close_user_id_changed?)
      Jobs.enqueue_at(auto_close_at, :close_topic, {topic_id: id, user_id: auto_close_user_id || user_id})
    end
  end

  # all users (in groups or directly targetted) that are going to get the pm
  def all_allowed_users
    # TODO we should probably change this from 3 queries to 1
    User.where('id in (?)', allowed_users.select('users.id').to_a + allowed_group_users.select('users.id').to_a)
  end

  # Additional rate limits on topics: per day and private messages per day
  def limit_topics_per_day
    RateLimiter.new(user, "topics-per-day:#{Date.today.to_s}", SiteSetting.max_topics_per_day, 1.day.to_i)
  end

  def limit_private_messages_per_day
    return unless private_message?
    RateLimiter.new(user, "pms-per-day:#{Date.today.to_s}", SiteSetting.max_private_messages_per_day, 1.day.to_i)
  end

  def fancy_title
    return title unless SiteSetting.title_fancy_entities?

    # We don't always have to require this, if fancy is disabled
    # see: http://meta.discourse.org/t/pattern-for-defer-loading-gems-and-profiling-with-perftools-rb/4629
    require 'redcarpet' unless defined? Redcarpet

    Redcarpet::Render::SmartyPants.render(title)
  end

  def sanitize_title
    if self.title.present?
      self.title = sanitize(title, tags: [], attributes: [])
      self.title.strip!
    end
  end

  def new_version_required?
    title_changed? || category_id_changed?
  end

  # Returns new topics since a date for display in email digest.
  def self.new_topics(since)
    Topic
      .visible
      .where(closed: false, archived: false)
      .created_since(since)
      .listable_topics
      .topic_list_order
      .includes(:user)
      .limit(5)
  end

  def update_meta_data(data)
    self.meta_data = (self.meta_data || {}).merge(data.stringify_keys)
    save
  end

  def reload(options=nil)
    @post_numbers = nil
    super(options)
  end

  def post_numbers
    @post_numbers ||= posts.order(:post_number).pluck(:post_number)
  end

  def has_meta_data_boolean?(key)
    meta_data_string(key) == 'true'
  end

  def meta_data_string(key)
    return unless meta_data.present?
    meta_data[key.to_s]
  end

  def self.visible
    where(visible: true)
  end

  def self.created_since(time_ago)
    where("created_at > ?", time_ago)
  end

  def self.listable_count_per_day(sinceDaysAgo=30)
    listable_topics.where('created_at > ?', sinceDaysAgo.days.ago).group('date(created_at)').order('date(created_at)').count
  end

  def private_message?
    self.archetype == Archetype.private_message
  end

  def links_grouped
    exec_sql("SELECT ftl.url,
                     ft.title,
                     ftl.link_topic_id,
                     ftl.reflection,
                     ftl.internal,
                     MIN(ftl.user_id) AS user_id,
                     SUM(clicks) AS clicks
              FROM topic_links AS ftl
                LEFT OUTER JOIN topics AS ft ON ftl.link_topic_id = ft.id
              WHERE ftl.topic_id = ?
              GROUP BY ftl.url, ft.title, ftl.link_topic_id, ftl.reflection, ftl.internal
              ORDER BY clicks DESC",
              id).to_a
  end

  # Search for similar topics
  def self.similar_to(title, raw)
    return [] unless title.present?
    return [] unless raw.present?

    # For now, we only match on title. We'll probably add body later on, hence the API hook
    Topic.select(sanitize_sql_array(["topics.*, similarity(topics.title, :title) AS similarity", title: title]))
         .visible
         .where(closed: false, archived: false)
         .listable_topics
         .limit(SiteSetting.max_similar_results)
         .order('similarity desc')
         .all
  end

  def update_status(property, status, user)
    Topic.transaction do

      # Special case: if it's pinned, update that
      if property.to_sym == :pinned
        update_pinned(status)
      else
        # otherwise update the column
        update_column(property == 'autoclosed' ? 'closed' : property, status)
      end

      key = "topic_statuses.#{property}_"
      key << (status ? 'enabled' : 'disabled')

      opts = {}

      # We don't bump moderator posts except for the re-open post.
      opts[:bump] = true if (property == 'closed' or property == 'autoclosed') and (!status)

      message = property != 'autoclosed' ? I18n.t(key) : I18n.t(key, count: (((self.auto_close_at||Time.zone.now) - self.created_at) / 86_400).round )

      add_moderator_post(user, message, opts)
    end
  end

  # Atomically creates the next post number
  def self.next_post_number(topic_id, reply = false)
    highest = exec_sql("select coalesce(max(post_number),0) as max from posts where topic_id = ?", topic_id).first['max'].to_i

    reply_sql = reply ? ", reply_count = reply_count + 1" : ""
    result = exec_sql("UPDATE topics SET highest_post_number = ? + 1#{reply_sql}
                       WHERE id = ? RETURNING highest_post_number", highest, topic_id)
    result.first['highest_post_number'].to_i
  end

  # If a post is deleted we have to update our highest post counters
  def self.reset_highest(topic_id)
    result = exec_sql "UPDATE topics
                        SET highest_post_number = (SELECT COALESCE(MAX(post_number), 0) FROM posts WHERE topic_id = :topic_id AND deleted_at IS NULL),
                            posts_count = (SELECT count(*) FROM posts WHERE deleted_at IS NULL AND topic_id = :topic_id)
                        WHERE id = :topic_id
                        RETURNING highest_post_number", topic_id: topic_id
    highest_post_number = result.first['highest_post_number'].to_i

    # Update the forum topic user records
    exec_sql "UPDATE topic_users
              SET last_read_post_number = CASE
                                          WHEN last_read_post_number > :highest THEN :highest
                                          ELSE last_read_post_number
                                          END,
                  seen_post_count = CASE
                                    WHEN seen_post_count > :highest THEN :highest
                                    ELSE seen_post_count
                                    END
              WHERE topic_id = :topic_id",
              highest: highest_post_number,
              topic_id: topic_id
  end

  # This calculates the geometric mean of the posts and stores it with the topic
  def self.calculate_avg_time
    exec_sql("UPDATE topics
              SET avg_time = x.gmean
              FROM (SELECT topic_id,
                           round(exp(avg(ln(avg_time)))) AS gmean
                    FROM posts
                    GROUP BY topic_id) AS x
              WHERE x.topic_id = topics.id")
  end

  def changed_to_category(cat)

    return if cat.blank?
    return if Category.where(topic_id: id).first.present?

    Topic.transaction do
      old_category = category

      if category_id.present? && category_id != cat.id
        Category.update_all 'topic_count = topic_count - 1', ['id = ?', category_id]
      end

      self.category_id = cat.id
      save

      CategoryFeaturedTopic.feature_topics_for(old_category)
      Category.update_all 'topic_count = topic_count + 1', id: cat.id
      CategoryFeaturedTopic.feature_topics_for(cat) unless old_category.try(:id) == cat.try(:id)
    end
  end

  def add_moderator_post(user, text, opts={})
    new_post = nil
    Topic.transaction do
      creator = PostCreator.new(user,
                                raw: text,
                                post_type: Post.types[:moderator_action],
                                no_bump: opts[:bump].blank?,
                                topic_id: self.id)
      new_post = creator.create
      increment!(:moderator_posts_count)
      new_post
    end

    if new_post.present?
      # If we are moving posts, we want to insert the moderator post where the previous posts were
      # in the stream, not at the end.
      new_post.update_attributes(post_number: opts[:post_number], sort_order: opts[:post_number]) if opts[:post_number].present?

      # Grab any links that are present
      TopicLink.extract_from(new_post)
    end

    new_post
  end

  # Changes the category to a new name
  def change_category(name)
    # If the category name is blank, reset the attribute
    if name.blank?
      if category_id.present?
        CategoryFeaturedTopic.feature_topics_for(category)
        Category.update_all 'topic_count = topic_count - 1', id: category_id
      end
      self.category_id = nil
      save
      return
    end

    cat = Category.where(name: name).first
    return if cat == category
    changed_to_category(cat)
  end

  def featured_user_ids
    [featured_user1_id, featured_user2_id, featured_user3_id, featured_user4_id].uniq.compact
  end

  # Invite a user to the topic by username or email. Returns success/failure
  def invite(invited_by, username_or_email)
    if private_message?
      # If the user exists, add them to the topic.
      user = User.find_by_username_or_email(username_or_email).first
      if user.present?
        if topic_allowed_users.create!(user_id: user.id)
          # Notify the user they've been invited
          user.notifications.create(notification_type: Notification.types[:invited_to_private_message],
                                    topic_id: id,
                                    post_number: 1,
                                    data: { topic_title: title,
                                            display_username: invited_by.username }.to_json)
          return true
        end
      elsif username_or_email =~ /^.+@.+$/
        # If the user doesn't exist, but it looks like an email, invite the user by email.
        return invite_by_email(invited_by, username_or_email)
      end
    else
      # Success is whether the invite was created
      return invite_by_email(invited_by, username_or_email).present?
    end

    false
  end

  # Invite a user by email and return the invite. Return the previously existing invite
  # if already exists. Returns nil if the invite can't be created.
  def invite_by_email(invited_by, email)
    lower_email = Email.downcase(email)
    invite = Invite.with_deleted.where('invited_by_id = ? and email = ?', invited_by.id, lower_email).first

    if invite.blank?
      invite = Invite.create(invited_by: invited_by, email: lower_email)
      unless invite.valid?

        # If the email already exists, grant permission to that user
        if invite.email_already_exists and private_message?
          user = User.where(email: lower_email).first
          topic_allowed_users.create!(user_id: user.id)
        end

        return
      end
    end

    # Recover deleted invites if we invite them again
    invite.recover if invite.deleted_at.present?

    topic_invites.create(invite_id: invite.id)
    Jobs.enqueue(:invite_email, invite_id: invite.id)
    invite
  end

  def move_posts_to_topic(moved_by, post_ids, destination_topic)
    to_move = posts.where(id: post_ids).order(:created_at)
    raise Discourse::InvalidParameters.new(:post_ids) if to_move.blank?

    first_post_number = nil
    Topic.transaction do
      # Find the max post number in the topic
      max_post_number = destination_topic.posts.maximum(:post_number) || 0

      to_move.each_with_index do |post, i|
        if post.post_number == 1
          # We have a special case for the OP, we copy it instead of deleting it.
          result = PostCreator.new(post.user,
                                  raw: post.raw,
                                  topic_id: destination_topic.id,
                                  acting_user: moved_by).create
        else
          first_post_number ||= post.post_number
          # Move the post and raise an error if it couldn't be moved
          row_count = Post.update_all ["post_number = :post_number, topic_id = :topic_id, sort_order = :post_number", post_number: max_post_number+i+1, topic_id: destination_topic.id], id: post.id, topic_id: id
          raise Discourse::InvalidParameters.new(:post_ids) if row_count == 0
        end
      end
    end


    first_post_number
  end

  def move_posts(moved_by, post_ids, opts)

    topic = nil
    first_post_number = nil

    if opts[:title].present?
      # If we're moving to a new topic...
      Topic.transaction do
        topic = Topic.create(user: moved_by, title: opts[:title], category: category)
        first_post_number = move_posts_to_topic(moved_by, post_ids, topic)
      end

    elsif opts[:destination_topic_id].present?
      # If we're moving to an existing topic...

      topic = Topic.where(id: opts[:destination_topic_id]).first
      Guardian.new(moved_by).ensure_can_see!(topic)
      first_post_number = move_posts_to_topic(moved_by, post_ids, topic)

    end

    # Add a moderator post explaining that the post was moved
    if topic.present?
      topic_url = "#{Discourse.base_url}#{topic.relative_url}"
      topic_link = "[#{topic.title}](#{topic_url})"

      add_moderator_post(moved_by, I18n.t("move_posts.moderator_post", count: post_ids.size, topic_link: topic_link), post_number: first_post_number)
      Jobs.enqueue(:notify_moved_posts, post_ids: post_ids, moved_by_id: moved_by.id)

      topic.update_statistics
      update_statistics
    end


    topic
  end

  # Updates the denormalized statistics of a topic including featured posters. They shouldn't
  # go out of sync unless you do something drastic live move posts from one topic to another.
  # this recalculates everything.
  def update_statistics
    feature_topic_users
    update_action_counts
    Topic.reset_highest(id)
  end

  def update_flagged_posts_count
    PostAction.update_flagged_posts_count
  end

  def update_action_counts
    PostActionType.types.keys.each do |type|
      count_field = "#{type}_count"
      update_column(count_field, Post.where(topic_id: id).sum(count_field))
    end
  end

  # Chooses which topic users to feature
  def feature_topic_users(args={})
    reload

    to_feature = posts

    # Don't include the OP or the last poster
    to_feature = to_feature.where('user_id NOT IN (?, ?)', user_id, last_post_user_id)

    # Exclude a given post if supplied (in the case of deletes)
    to_feature = to_feature.where("id <> ?", args[:except_post_id]) if args[:except_post_id].present?

    # Clear the featured users by default
    Topic.featured_users_count.times do |i|
      send("featured_user#{i+1}_id=", nil)
    end

    # Assign the featured_user{x} columns
    to_feature = to_feature.group(:user_id).order('count_all desc').limit(Topic.featured_users_count)

    to_feature.count.keys.each_with_index do |user_id, i|
      send("featured_user#{i+1}_id=", user_id)
    end

    save
  end

  # Create the summary of the interesting posters in a topic. Cheats to avoid
  # many queries.
  def posters_summary(topic_user = nil, current_user = nil, opts={})
    return @posters_summary if @posters_summary.present?
    descriptions = {}

    # Use an avatar lookup object if we have it, otherwise create one just for this forum topic
    al = opts[:avatar_lookup]
    if al.blank?
      al = AvatarLookup.new([user_id, last_post_user_id, featured_user1_id, featured_user2_id, featured_user3_id])
    end

    # Helps us add a description to a poster
    add_description = lambda do |u, desc|
      if u.present?
        descriptions[u.id] ||= []
        descriptions[u.id] << I18n.t(desc)
      end
    end

    add_description.call(al[user_id], :original_poster)
    add_description.call(al[featured_user1_id], :most_posts)
    add_description.call(al[featured_user2_id], :frequent_poster)
    add_description.call(al[featured_user3_id], :frequent_poster)
    add_description.call(al[featured_user4_id], :frequent_poster)
    add_description.call(al[last_post_user_id], :most_recent_poster)


    @posters_summary = [al[user_id],
                        al[last_post_user_id],
                        al[featured_user1_id],
                        al[featured_user2_id],
                        al[featured_user3_id],
                        al[featured_user4_id]
                        ].compact.uniq[0..4]

    unless @posters_summary[0] == al[last_post_user_id]
      # shuffle last_poster to back
      @posters_summary.reject!{|u| u == al[last_post_user_id]}
      @posters_summary << al[last_post_user_id]
    end
    @posters_summary.map! do |p|
      if p
        result = TopicPoster.new
        result.user = p
        result.description = descriptions[p.id].join(', ')
        result.extras = "latest" if al[last_post_user_id] == p
        result
      else
        nil
      end
    end.compact!

    @posters_summary
  end

  # Enable/disable the star on the topic
  def toggle_star(user, starred)
    Topic.transaction do
      TopicUser.change(user, id, {starred: starred}.merge( starred ? {starred_at: DateTime.now, unstarred_at: nil} : {unstarred_at: DateTime.now}))

      # Update the star count
      exec_sql "UPDATE topics
                SET star_count = (SELECT COUNT(*)
                                  FROM topic_users AS ftu
                                  WHERE ftu.topic_id = topics.id
                                    AND ftu.starred = true)
                WHERE id = ?", id

      if starred
        FavoriteLimiter.new(user).performed!
      else
        FavoriteLimiter.new(user).rollback!
      end
    end
  end

  def self.starred_counts_per_day(sinceDaysAgo=30)
    TopicUser.where('starred_at > ?', sinceDaysAgo.days.ago).group('date(starred_at)').order('date(starred_at)').count
  end

  # Enable/disable the mute on the topic
  def toggle_mute(user, muted)
    TopicUser.change(user, self.id, notification_level: muted?(user) ? TopicUser.notification_levels[:regular] : TopicUser.notification_levels[:muted] )
  end

  def slug
    unless slug = read_attribute(:slug)
      return '' unless title.present?
      slug = Slug.for(title).presence || "topic"
      if new_record?
        write_attribute(:slug, slug)
      else
        update_column(:slug, slug)
      end
    end

    slug
  end

  def title=(t)
    slug = ""
    slug = (Slug.for(t).presence || "topic") if t.present?
    write_attribute(:slug, slug)
    write_attribute(:title,t)
  end

  def last_post_url
    "/t/#{slug}/#{id}/#{posts_count}"
  end


  def self.url(id, slug, post_number=nil)
    url = "#{Discourse.base_url}/t/#{slug}/#{id}"
    url << "/#{post_number}" if post_number.to_i > 1
    url
  end

  def relative_url(post_number=nil)
    url = "/t/#{slug}/#{id}"
    url << "/#{post_number}" if post_number.to_i > 1
    url
  end

  def muted?(user)
    return false unless user && user.id
    tu = topic_users.where(user_id: user.id).first
    tu && tu.notification_level == TopicUser.notification_levels[:muted]
  end

  def clear_pin_for(user)
    return unless user.present?
    TopicUser.change(user.id, id, cleared_pinned_at: Time.now)
  end

  def update_pinned(status)
    update_column(:pinned_at, status ? Time.now : nil)
  end

  def draft_key
    "#{Draft::EXISTING_TOPIC}#{id}"
  end

  # notification stuff
  def notify_watch!(user)
    TopicUser.change(user, id, notification_level: TopicUser.notification_levels[:watching])
  end

  def notify_tracking!(user)
    TopicUser.change(user, id, notification_level: TopicUser.notification_levels[:tracking])
  end

  def notify_regular!(user)
    TopicUser.change(user, id, notification_level: TopicUser.notification_levels[:regular])
  end

  def notify_muted!(user)
    TopicUser.change(user, id, notification_level: TopicUser.notification_levels[:muted])
  end

  def auto_close_days=(num_days)
    @ignore_category_auto_close = true
    self.auto_close_at = (num_days and num_days.to_i > 0.0 ? num_days.to_i.days.from_now : nil)
  end

  def secure_category?
    category && category.secure
  end
end
