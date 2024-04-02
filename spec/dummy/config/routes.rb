# frozen_string_literal: true

Rails.application.routes.draw do
  mount Rswag::Ui::Engine => '/'
  mount Rswag::Api::Engine => '/'
  mount Lab::Engine => '/'
end
