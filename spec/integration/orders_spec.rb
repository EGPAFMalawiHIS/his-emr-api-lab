# frozen_string_literal: true

require 'swagger_helper'

def order_schema
  {
    type: :object,
    properties: {
      order_id: { type: :integer },
      patient_id: { type: :integer },
      encounter_id: { type: :integer },
      order_date: { type: :string, format: :datetime },
      accession_number: { type: :string },
      specimen: {
        type: :object,
        properties: {
          concept_id: { type: :integer },
          name: { type: :string }
        },
        required: %i[concept_id name]
      },
      requesting_clinician: { type: :string, nullable: true },
      target_lab: { type: :string },
      reason_for_test: {
        type: :object,
        properties: {
          concept_id: { type: :integer },
          name: { type: :string }
        },
        required: %i[concept_id name]
      },
      tests: {
        type: :array,
        items: {
          type: :object,
          properties: {
            id: { type: :integer },
            concept_id: { type: :integer },
            name: { type: :string },
            result: {
              type: :object,
              nullable: true,
              properties: {
                id: { type: :integer },
                value: { type: :string, nullable: true },
                date: { type: :string, format: :datetime, nullable: true }
              },
              required: %i[id value date]
            }
          },
          required: %i[id concept_id name]
        }
      }
    },
    required: %i[order_id specimen reason_for_test accession_number patient_id order_date]
  }
end

describe 'orders' do
  before(:each) do
    @encounter_type = create(:encounter_type, name: Lab::LabEncounter::ENCOUNTER_TYPE_NAME)
    @order_type = create(:order_type, name: Lab::LabOrder::ORDER_TYPE_NAME)
    @test_type = create(:concept_name, name: Lab::LabOrder::TEST_TYPE_CONCEPT_NAME).concept
    @reason_for_test = create(:concept_name, name: Lab::LabOrder::REASON_FOR_TEST_CONCEPT_NAME).concept
    @requesting_clinician = create(:concept_name, name: Lab::LabOrder::REQUESTING_CLINICIAN_CONCEPT_NAME).concept
    @target_lab = create(:concept_name, name: Lab::LabOrder::TARGET_LAB_CONCEPT_NAME).concept
  end

  path '/api/v1/lab/orders' do
    post 'Create order' do
      tags 'Lab'

      description <<~DESC
        Create a lab order for a test.

        Broadly a lab order consists of a test type and a number of specimens.
        To each specimen is assigned a tracking number which can be used
        to query the status and results of the specimen.
      DESC

      consumes 'application/json'
      produces 'application/json'

      parameter name: :orders, in: :body, schema: {
        type: :object,
        properties: {
          orders: {
            type: :array,
            items: {
              properties: {
                encounter_id: { type: :integer },
                specimen: {
                  type: :object,
                  properties: {
                    concept_id: {
                      type: :integer,
                      description: 'Specimen type concept ID (see GET /lab/test_types)'
                    }
                  }
                },
                tests: {
                  type: :array,
                  items: {
                    type: :object,
                    properties: {
                      concept_id: {
                        type: :integer,
                        description: 'Test type concept ID (see GET /lab/test_types)'
                      }
                    }
                  }
                },
                requesting_clinician: {
                  type: :string,
                  description: 'Fullname of the clinician requesting the test (defaults to orderer)'
                },
                target_lab: { type: :string },
                reason_for_test_id: {
                  type: :string,
                  description: 'One of routine, targeted, or confirmatory'
                }
              },
              required: %i[encounter_id test_type_id target_lab reason_for_test_id]
            }
          }
        }
      }

      security [api_key: []]

      let(:Authorization) { 'dummy-key' }
      let(:orders) do
        {
          orders: [
            {
              encounter_id: create(:encounter, type: @encounter_type).encounter_id,
              specimen: { concept_id: create(:concept_name, name: 'Viral load').concept_id },
              tests: [{ concept_id: create(:concept_name, name: 'FBC').concept_id }],
              requesting_clinician: 'Barry Allen',
              target_lab: 'Starlabs',
              reason_for_test_id: create(:concept_name, name: 'Routine').concept_id
            }
          ]
        }
      end

      response 201, 'Created' do
        schema type: :array, items: order_schema

        run_test! do |response|
          response = JSON.parse(response.body)
          order = orders[:orders].first

          expect(response[0]['specimen']['concept_id']).to eq(order[:specimen][:concept_id])
          expect(response[0]['requesting_clinician']).to eq(order[:requesting_clinician])
          expect(response[0]['target_lab']).to eq(order[:target_lab])
          expect(response[0]['reason_for_test']['concept_id']).to eq(order[:reason_for_test_id])
          expect(Set.new(response[0]['tests'].map { |test| test['concept_id'] }))
            .to eq(Set.new(order[:tests].map { |test| test[:concept_id] }))
        end
      end
    end

    get 'Retrieve lab orders' do
      tags 'Lab'
      description 'Search/retrieve for lab orders.'

      produces 'application/json'

      security [api_key: []]

      parameter name: :patient_id,
                in: :query,
                required: false,
                type: :integer,
                description: 'Filter orders using patient_id'

      parameter name: :accession_number,
                in: :query,
                required: false,
                type: :integer,
                description: 'Filter orders using sample accession number'

      parameter name: :date,
                in: :query,
                required: false,
                type: :date,
                description: 'Select results falling on a specific date'

      def create_order(no_specimen: false)
        encounter = create(:encounter, type: @encounter_type)
        order = create(:order, encounter: encounter,
                               patient_id: encounter.patient_id,
                               order_type: @order_type,
                               start_date: Date.today,
                               concept: create(:concept_name).concept,
                               accession_number: SecureRandom.alphanumeric(5))

        return if no_specimen

        observations = [
          [@test_type, value_coded: create(:concept_name).concept_id],
          [@target_lab, value_text: 'Ze Lab'],
          [@reason_for_test, value_coded: create(:concept_name).concept_id],
          [@requesting_clinician, value_text: Faker::Name.name]
        ]

        observations.each do |concept, params,|
          create(:observation, encounter: encounter,
                               concept: concept,
                               person_id: encounter.patient_id,
                               order: order,
                               obs_datetime: Time.now,
                               **params)
        end

        order
      end

      before(:each) do
        @orders = 5.times.map { |i| create_order(no_specimen: i.odd?) }
      end

      let(:Authorization) { 'dummy' }
      let(:patient_id) { @orders.first.patient_id }
      let(:accession_number) { @orders.first.accession_number }
      let(:date) { @orders.first.start_date }

      response 200, 'Success' do
        schema type: :array, items: order_schema

        run_test! do |response|
          response = JSON.parse(response.body)

          expect(response.size).to eq(1)
          expect(response[0]['patient_id']).to eq(patient_id)
          expect(response[0]['order_date'].to_date).to eq(date)
          expect(response[0]['accession_number']).to eq(accession_number)
        end
      end
    end
  end
end
