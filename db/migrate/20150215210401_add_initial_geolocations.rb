class AddInitialGeolocations < ActiveRecord::Migration

  def change
    add_column :products, :initial_geolocation, :point, srid: 4326
  end
  
end
