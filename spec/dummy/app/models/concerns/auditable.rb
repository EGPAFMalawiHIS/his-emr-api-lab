# frozen_string_literal: true

# Gives ActiveRecord models an auditable behaviour
#
# Models with the Auditable behaviour automagically get their
# date_changed and changed_by field set to the currently logged
# in user.
#
# USAGE:
#  class ApplicationRecord < ActiveRecord::Model
#    include Auditable
#    ...
#  end
module Auditable
  extend ActiveSupport::Concern

  included do
    before_save :update_change_trail
    before_create :update_create_trail
  end

  # Saves current user after every save
  def update_change_trail
    return unless auditable?

    self.changed_by ||= User.current&.user_id
    Rails.logger.warn 'Auditable::update_change_trail called outside login' unless changed_by

    self.date_changed = Time.now
  end

  def update_create_trail
    return unless auditable?

    self.creator ||= User.current&.user_id
    Rails.logger.warn 'Auditable::update_create_trail called outside login' unless creator

    self.date_created = Time.now
  end

  def auditable?
    respond_to?(:changed_by) && respond_to?(:date_changed)
  end
end
