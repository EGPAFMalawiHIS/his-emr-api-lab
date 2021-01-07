# frozen_string_literal: true

require 'rails_helper'

module Lab
  RSpec.describe OrdersService do
    subject { OrdersService }

    before :each do
      # Initialize Lab metadata...
      @encounter_type = create(:encounter_type, name: LabEncounter::ENCOUNTER_TYPE_NAME)
      @order_type = create(:order_type, name: LabOrder::ORDER_TYPE_NAME)

      [LabOrder::SPECIMEN_TYPE_CONCEPT_NAME,
       LabOrder::REQUESTING_CLINICIAN_CONCEPT_NAME,
       LabOrder::TARGET_LAB_CONCEPT_NAME,
       LabOrder::REASON_FOR_TEST_CONCEPT_NAME].each do |name|
        create(:concept_name, name: name)
      end
    end

    describe :order_test do
      let(:encounter) { create(:encounter, type: @encounter_type) }
      let(:test_type) { create(:concept_name) }
      let(:specimen_types) { create_list(:concept, 5) }
      let(:reason_for_test) { create(:concept_name) }

      let(:params) do
        ActiveSupport::HashWithIndifferentAccess.new(
          encounter_id: encounter.encounter_id,
          test_type_id: test_type.concept_id,
          specimen_types: specimen_types.map do |type|
            { concept_id: type.concept_id }
          end,
          start_date: Date.today,
          end_date: 5.days.from_now,
          requesting_clinician: 'Doctor Seuss',
          target_lab: 'Halls of Valhalla',
          reason_for_test_id: reason_for_test.concept_id
        )
      end

      it 'creates an encounter if one is not specified' do
        expect { subject.order_test(params) }.to change(Lab::LabOrder.all, :count).by(1)
      end

      it 'uses provided encounter_id to create order' do
        order = subject.order_test(params)
        expect(order['encounter_id']).to eq(params[:encounter_id])
      end

      it 'requires encounter_id, or patient_id and program_id' do
        params_subset = params.delete_if { |key, _| %w[encounter_id patient_id program_id].include?(key) }

        expect { subject.order_test(params_subset) }.to raise_error(::InvalidParameterError)
      end
    end

    describe :search_orders do
      before(:each) do
        encounter = create(:encounter, type: @encounter_type)
        @lab_order = create(:order, type: @order_type,
                                    encounter: encounter,
                                    patient_id: encounter.patient_id,
                                    start_date: Date.today)
      end

      # TODO: Implement the following tests

      xit 'retrieves orders by patient_id' do
      end

      xit 'retrieves orders by accession_number' do
      end

      xit 'retrieves orders by date' do
      end

      xit 'retrieves orders by pending_results status' do
      end

      xit 'retrieves all orders when no filters are specified' do
      end
    end
  end
end
