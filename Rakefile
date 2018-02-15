require_relative 'config/application'

Rails.application.load_tasks

task seed: :environment do
  User.delete_all
  10_000.times do
    User.create(
      name: Faker::Name.name_with_middle,
      age: rand(100)
    )
  end
end
