# frozen_string_literal: true

require 'cgi/util'

require_relative './api'
require_relative './exceptions'
require_relative './order_serializer'
require_relative './utils'

module Lab
  module Lims
    LIMS_LOG_PATH = Rails.root.join('log/lims')
    Dir.mkdir(LIMS_LOG_PATH) unless File.exist?(LIMS_LOG_PATH)

    ##
    # Pull/Push orders from/to the LIMS queue (Oops meant CouchDB).
    class Worker
      include Utils

      attr_reader :lims_api

      def self.start
        File.open(LIMS_LOG_PATH.join('worker.lock'), File::WRONLY | File::CREAT, 0o644) do |fout|
          fout.flock(File::LOCK_EX)

          User.current = Utils.lab_user

          fout.write("Worker ##{Process.pid} started at #{Time.now}")
          worker = new(Api.new)
          worker.pull_orders
          worker.push_orders
        end
      end

      def initialize(lims_api)
        @lims_api = lims_api
      end

      def push_orders(batch_size: 100)
        loop do
          logger.info('Fetching new orders...')
          orders = LabOrder.where.not(order_id: LimsOrderMapping.all.select(:order_id))
                           .limit(batch_size)

          if orders.empty?
            logger.info('No new orders available; exiting...')
            break
          end

          orders.each { |order| push_order(order) }
        end
      end

      def push_order_by_id(order_id)
        order = LabOrder.find(order_id)
        push_order(order)
      end

      ##
      # Pushes given order to LIMS queue
      def push_order(order)
        logger.info("Pushing order ##{order.order_id}")

        order_dto = OrderSerializer.serialize_order(order)
        mapping = LimsOrderMapping.find_by(order_id: order.order_id)

        ActiveRecord::Base.transaction do
          if mapping
            lims_api.update_order(mapping.lims_id, order_dto)
            mapping.update(pushed_at: Time.now)
          else
            update = lims_api.create_order(order_dto)
            LimsOrderMapping.create!(order: order, lims_id: update['id'], revision: update['rev'], pushed_at: Time.now)
          end
        end

        order_dto
      end

      ##
      # Pulls orders from the LIMS queue and writes them to the local database
      def pull_orders
        logger.info("Retrieving LIMS orders starting from #{last_seq}")

        lims_api.consume_orders(from: last_seq, limit: 100) do |order_dto, context|
          logger.debug("Retrieved order ##{order_dto[:tracking_number]}: #{order_dto}")

          patient = find_patient_by_nhid(order_dto[:patient][:id])
          unless patient
            logger.debug("Discarding order: Non local patient ##{order_dto[:patient][:id]} on order ##{order_dto[:tracking_number]}")
            next [:rejected, "Patient NPID, '#{order_dto[:patient][:id]}', didn't match any local NPIDs"]
          end

          diff = match_patient_demographics(patient, order_dto['patient'])
          if diff.empty?
            save_order(patient, order_dto)
          else
            save_failed_import(order_dto, 'Demographics not matching', diff)
          end

          update_last_seq(context.current_seq)

          [:accepted, "Patient NPID, '#{order_dto[:patient][:id]}', matched"]
        rescue DuplicateNHID
          logger.warn("Failed to import order due to duplicate patient NHID: #{order_dto[:patient][:id]}")
          save_failed_import(order_dto, "Duplicate local patient NHID: #{order_dto[:patient][:id]}")
        rescue MissingAccessionNumber
          logger.warn("Failed to import order due to missing accession number: #{order_dto[:_id]}")
          save_failed_import(order_dto, 'Order missing tracking number')
        rescue LimsException => e
          logger.warn("Failed to import order due to #{e.class} - #{e.message}")
          save_failed_import(order_dto, e.message)
        end
      end

      protected

      def last_seq
        File.open(last_seq_path, File::RDONLY | File::CREAT, 0o644) do |fin|
          data = fin.read&.strip
          return nil if data.blank?

          return data
        end
      end

      def update_last_seq(last_seq)
        File.open(last_seq_path, File::WRONLY | File::CREAT, 0o644) do |fout|
          fout.flock(File::LOCK_EX)

          fout.write(last_seq.to_s)
        end
      end

      private

      def find_patient_by_nhid(nhid)
        national_id_type = PatientIdentifierType.where(name: ['National id', 'Old Identification Number'])
        identifiers = PatientIdentifier.where(type: national_id_type, identifier: nhid)
        if identifiers.count.zero?
          identifiers = PatientIdentifier.unscoped.where(voided: 1, type: national_id_type, identifier: nhid)
        end
        return nil if identifiers.count.zero?

        patients = Patient.where(patient_id: identifiers.select(:patient_id))
                          .distinct(:patient_id)
                          .all

        if patients.size > 1
          raise DuplicateNHID, "Duplicate National Health ID: #{nhid}"
        end

        patients.first
      end

      ##
      # Matches a local patient's demographics to a LIMS patient's demographics
      def match_patient_demographics(local_patient, lims_patient)
        diff = {}
        person = Person.find(local_patient.id)
        person_name = PersonName.find_by_person_id(local_patient.id)

        unless (person.gender.blank? && lims_patient['gender'].blank?)\
          || person.gender&.first&.casecmp?(lims_patient['gender']&.first)
          diff[:gender] = { local: person.gender, lims: lims_patient['gender'] }
        end

        unless names_match?(person_name&.given_name, lims_patient['first_name'])
          diff[:given_name] = { local: person_name&.given_name, lims: lims_patient['first_name'] }
        end

        unless names_match?(person_name&.family_name, lims_patient['last_name'])
          diff[:family_name] = { local: person_name&.family_name, lims: lims_patient['last_name'] }
        end

        diff
      end

      def names_match?(name1, name2)
        name1 = name1&.gsub(/'/, '')&.strip
        name2 = name2&.gsub(/'/, '')&.strip

        return true if name1.blank? && name2.blank?

        return false if name1.blank? || name2.blank?

        name1.casecmp?(name2)
      end

      def save_order(patient, order_dto)
        raise MissingAccessionNumber if order_dto[:tracking_number].blank?

        logger.info("Importing LIMS order ##{order_dto[:tracking_number]}")
        mapping = LimsOrderMapping.find_by(lims_id: order_dto[:_id])

        ActiveRecord::Base.transaction do
          if mapping
            order = update_order(patient, mapping.order_id, order_dto)
            mapping.update(pulled_at: Time.now)
          else
            order = create_order(patient, order_dto)
            LimsOrderMapping.create!(lims_id: order_dto[:_id],
                                     order_id: order['id'],
                                     pulled_at: Time.now,
                                     revision: order_dto['_rev'])
          end

          order
        end
      end

      def create_order(patient, order_dto)
        logger.debug("Creating order ##{order_dto['_id']}")
        order = OrdersService.order_test(order_dto.to_order_service_params(patient_id: patient.patient_id))
        unless order_dto['test_results'].empty?
          update_results(order, order_dto['test_results'])
        end

        order
      end

      def update_order(patient, order_id, order_dto)
        logger.debug("Updating order ##{order_dto['_id']}")
        order = OrdersService.update_order(order_id, order_dto.to_order_service_params(patient_id: patient.patient_id)
                                                              .merge(force_update: true))
        unless order_dto['test_results'].empty?
          update_results(order, order_dto['test_results'])
        end

        order
      end

      def update_results(order, lims_results)
        logger.debug("Updating results for order ##{order[:accession_number]}: #{lims_results}")

        lims_results.each do |test_name, test_results|
          test = find_test(order['id'], test_name)
          unless test
            logger.warn("Couldn't find test, #{test_name}, in order ##{order[:id]}")
            next
          end

          measures = test_results['results'].map do |indicator, value|
            measure = find_measure(order, indicator, value)
            next nil unless measure

            measure
          end

          measures = measures.compact

          next if measures.empty?

          creator = format_result_entered_by(test_results['result_entered_by'])

          ResultsService.create_results(test.id, provider_id: User.current.person_id,
                                                 date: Utils.parse_date(test_results['date_result_entered'], order[:order_date].to_s),
                                                 comments: "LIMS import: Entered by: #{creator}",
                                                 measures: measures)
        end
      end

      def find_test(order_id, test_name)
        test_name = Utils.translate_test_name(test_name)
        test_concept = Utils.find_concept_by_name(test_name)
        raise "Unknown test name, #{test_name}!" unless test_concept

        LabTest.find_by(order_id: order_id, value_coded: test_concept.concept_id)
      end

      def find_measure(_order, indicator_name, value)
        indicator = Utils.find_concept_by_name(indicator_name)
        unless indicator
          logger.warn("Result indicator #{indicator_name} not found in concepts list")
          return nil
        end

        value_modifier, value, value_type = parse_lims_result_value(value)
        return nil if value.blank?

        ActiveSupport::HashWithIndifferentAccess.new(
          indicator: { concept_id: indicator.concept_id },
          value_type: value_type,
          value: value_type == 'numeric' ? value.to_f : value,
          value_modifier: value_modifier.blank? ? '=' : value_modifier
        )
      end

      def parse_lims_result_value(value)
        value = value['result_value']&.strip
        return nil, nil, nil if value.blank?

        match = value&.match(/^(>|=|<|<=|>=)(.*)$/)
        return nil, value, guess_result_datatype(value) unless match

        [match[1], match[2], guess_result_datatype(match[2])]
      end

      def guess_result_datatype(result)
        return 'numeric' if result.strip.match?(/^[+-]?(\d+(\.\d+)|\.\d+)?$/)

        'text'
      end

      def format_result_entered_by(result_entered_by)
        first_name = result_entered_by['first_name']
        last_name = result_entered_by['last_name']
        phone_number = result_entered_by['phone_number']
        id = result_entered_by['id'] # Looks like a user_id of some sort

        "#{id}:#{first_name} #{last_name}:#{phone_number}"
      end

      def save_failed_import(order_dto, reason, diff = nil)
        logger.info("Failed to import LIMS order ##{order_dto[:tracking_number]} due to '#{reason}'")
        LimsFailedImport.create!(lims_id: order_dto[:_id],
                                 tracking_number: order_dto[:tracking_number],
                                 patient_nhid: order_dto[:patient][:id],
                                 reason: reason,
                                 diff: diff&.to_json)
      end

      def last_seq_path
        LIMS_LOG_PATH.join('last_seq.dat')
      end
    end
  end
end
