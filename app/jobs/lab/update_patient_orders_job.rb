# frozen_string_literal: true

module Lab
  ##
  # Fetches updates on a patient's orders from external sources.
  class UpdatePatientOrdersJob < ApplicationJob
    def perform(patient_id)
      Rails.logger.info('Initialising LIMS REST API...')

      User.current = Lab::Lims::Utils.lab_user
      Location.current = Location.find_by_name('ART clinic')

      lims_api = Lab::Lims::Api::RestApi.new
      worker = Lab::Lims::Worker.new(lims_api)
      worker.pull_orders(patient_id: patient_id)
    end
  end
end
