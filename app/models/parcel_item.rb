# = Informations
#
# == License
#
# Ekylibre - Simple agricultural ERP
# Copyright (C) 2008-2009 Brice Texier, Thibaud Merigon
# Copyright (C) 2010-2012 Brice Texier
# Copyright (C) 2012-2017 Brice Texier, David Joulin
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see http://www.gnu.org/licenses.
#
# == Table: parcel_items
#
#  analysis_id                   :integer
#  created_at                    :datetime         not null
#  creator_id                    :integer
#  currency                      :string
#  delivery_id                   :integer
#  delivery_mode                 :string
#  equipment_id                  :integer
#  id                            :integer          not null, primary key
#  lock_version                  :integer          default(0), not null
#  non_compliant                 :boolean
#  non_compliant_detail          :string
#  parcel_id                     :integer          not null
#  parted                        :boolean          default(FALSE), not null
#  population                    :decimal(19, 4)
#  pretax_amount                 :decimal(19, 4)   default(0.0), not null
#  product_enjoyment_id          :integer
#  product_id                    :integer
#  product_identification_number :string
#  product_localization_id       :integer
#  product_movement_id           :integer
#  product_name                  :string
#  product_ownership_id          :integer
#  purchase_invoice_item_id      :integer
#  purchase_order_item_id        :integer
#  role                          :string
#  sale_item_id                  :integer
#  shape                         :geometry({:srid=>4326, :type=>"multi_polygon"})
#  source_product_id             :integer
#  source_product_movement_id    :integer
#  transporter_id                :integer
#  unit_pretax_amount            :decimal(19, 4)   default(0.0), not null
#  unit_pretax_stock_amount      :decimal(19, 4)   default(0.0), not null
#  updated_at                    :datetime         not null
#  updater_id                    :integer
#  variant_id                    :integer
#
class ParcelItem < Ekylibre::Record::Base
  attr_readonly :parcel_id
  attr_accessor :product_nature_variant_id
  enumerize :delivery_mode, in: %i[transporter us third none], predicates: { prefix: true }, scope: true, default: :us
  belongs_to :analysis
  belongs_to :parcel, inverse_of: :items
  belongs_to :product

  with_options class_name: 'PurchaseItem' do
    belongs_to :purchase_order_item, foreign_key: 'purchase_order_item_id'
    belongs_to :purchase_invoice_item, foreign_key: 'purchase_invoice_item_id'
  end

  belongs_to :sale_item
  belongs_to :delivery
  belongs_to :transporter, class_name: 'Entity'
  belongs_to :source_product, class_name: 'Product'
  belongs_to :source_product_movement, class_name: 'ProductMovement', dependent: :destroy
  belongs_to :variant, class_name: 'ProductNatureVariant'
  belongs_to :equipment, class_name: 'Product'
  has_one :nature, through: :variant
  has_one :storage, through: :parcel
  has_one :contract, through: :parcel
  has_one :product_enjoyment, as: :originator, dependent: :destroy
  has_one :product_localization, as: :originator, dependent: :destroy
  has_one :product_movement, as: :originator, dependent: :destroy
  has_one :product_ownership, as: :originator, dependent: :destroy
  has_many :storings, class_name: 'ParcelItemStoring', inverse_of: :parcel_item, foreign_key: :parcel_item_id, dependent: :destroy

  # [VALIDATORS[ Do not edit these lines directly. Use `rake clean:validations`.
  validates :currency, :non_compliant_detail, :product_identification_number, :product_name, :role, length: { maximum: 500 }, allow_blank: true
  validates :non_compliant, inclusion: { in: [true, false] }, allow_blank: true
  validates :parted, inclusion: { in: [true, false] }
  validates :population, numericality: { greater_than: -1_000_000_000_000_000, less_than: 1_000_000_000_000_000 }, allow_blank: true
  validates :pretax_amount, :unit_pretax_amount, :unit_pretax_stock_amount, presence: true, numericality: { greater_than: -1_000_000_000_000_000, less_than: 1_000_000_000_000_000 }
  validates :parcel, presence: true
  # ]VALIDATORS]
  validates :source_product, presence: { if: :parcel_outgoing? }
  validates :variant, presence: true
  validates :product, presence: true, unless: proc { |item| !item.parcel.try(:prepared?) }

  validates :population, presence: true, numericality: { less_than_or_equal_to: 1,
                                                         if: :product_is_unitary?,
                                                         message: 'activerecord.errors.messages.unitary_in_parcel'.t }
  validates :product_name, presence: { if: -> { product_is_identifiable? && parcel_incoming? } }
  validates :product_identification_number, presence: { if: -> { product_is_identifiable? && parcel_incoming? } }

  scope :with_nature, ->(nature) { joins(:parcel).merge(Parcel.with_nature(nature)) }

  alias_attribute :quantity, :population

  accepts_nested_attributes_for :product
  accepts_nested_attributes_for :storings, allow_destroy: true

  # delegate :net_mass, to: :product
  delegate :allow_items_update?, :remain_owner, :planned_at,
           :ordered_at, :recipient, :in_preparation_at,
           :prepared_at, :given_at, :outgoing?, :incoming?,
           :separated_stock?, :currency, to: :parcel, prefix: true

  delegate :draft?, :given?, to: :reception, prefix: true, allow_nil: true
  delegate :draft?, :in_preparation?, :prepared?, :given?, to: :shipment, prefix: true

  before_validation do
    # binding.pry
    self.currency = parcel_currency if parcel
    if variant
      catalog_item = variant.catalog_items.of_usage(:stock)
      if catalog_item.any? && catalog_item.first.pretax_amount != 0.0
        self.unit_pretax_stock_amount = catalog_item.first.pretax_amount
      end
      # purchase contrat case
      if contract && contract.items.where(variant: variant).any?
        item = contract.items.where(variant_id: variant.id).first
        self.unit_pretax_amount ||= item.unit_pretax_amount if item && item.unit_pretax_amount
      end
    end
    read_at = parcel ? parcel_prepared_at : Time.zone.now
    self.population ||= product_is_unitary? ? 1 : 0

    # Use the unit_amount of purchase_order_item if amount equal to zero
    if self.purchase_order_item.present? && self.unit_pretax_amount.zero?
      self.unit_pretax_amount = purchase_order_item.unit_pretax_amount
    else
      self.unit_pretax_amount ||= 0.0
    end

    self.pretax_amount = population * self.unit_pretax_amount
    next if parcel_incoming?

    if sale_item
      self.variant = sale_item.variant
    elsif purchase_order_item
      self.variant = purchase_order_item.variant
    elsif parcel_outgoing?
      self.variant = source_product.variant if source_product
      self.population = source_product.population if population.nil? || population.zero?
    end
    true
  end

  after_save do
    if Preference[:catalog_price_item_addition_if_blank]
      if parcel_incoming?
        for usage in %i[stock purchase]
          # set stock catalog price if blank
          catalog = Catalog.by_default!(usage)
          unless variant.catalog_items.of_usage(usage).any? || unit_pretax_amount.blank? || unit_pretax_amount.zero?
            variant.catalog_items.create!(catalog: catalog, all_taxes_included: false, amount: unit_pretax_amount, currency: currency) if catalog
          end
        end
      end
    end
  end

  ALLOWED = %w[
    product_localization_id
    product_movement_id
    product_enjoyment_id
    product_ownership_id
    unit_pretax_stock_amount
    unit_pretax_amount
    pretax_amount
    purchase_order_item_id
    purchase_invoice_item_id
    sale_item_id
    updated_at
    updater_id
  ].freeze
  protect(allow_update_on: ALLOWED, on: %i[create destroy update]) do
    !parcel_allow_items_update?
  end

  def prepared?
    (!parcel_incoming? && source_product.present?) ||
      (parcel_incoming? && variant.present?)
  end

  def trade_item
    parcel_incoming? ? purchase_order_item : sale_item
  end

  def stock_amount
    population * unit_pretax_stock_amount
  end

  def status
    prepared? ? :go : variant.present? ? :caution : :stop
  end

  def product_is_identifiable?
    [variant, source_product].reduce(false) do |acc, product_input|
      acc || Maybe(product_input).identifiable?.or_else(false)
    end
  end

  def product_is_unitary?
    [variant, source_product].reduce(false) do |acc, product_input|
      acc || Maybe(product_input).population_counting_unitary?.or_else(false)
    end
  end

  # Set started_at/stopped_at in tasks concerned by preparation of item
  # It takes product in stock
  def check
    checked_at = parcel_prepared_at
    state = true
    state, msg = check_incoming(checked_at) if parcel_incoming?
    check_outgoing(checked_at) if parcel_outgoing?
    return state, msg unless state
    save!
  end

  def name
    Maybe(source_product || variant || product).name.or_else(nil)
  end

  # Mark items as given, and so change enjoyer and ownership if needed at
  # this moment.
  def give
    transaction do
      give_outgoing if parcel_outgoing?
      give_incoming if parcel_incoming?
    end
  end

  protected

  def check_incoming(checked_at)
    product_params = {}
    no_fusing = parcel_separated_stock? || product_is_unitary?

    product_params[:name] = product_name
    product_params[:name] ||= "#{variant.name} (#{parcel.number})"
    product_params[:identification_number] = product_identification_number
    product_params[:initial_born_at] = [checked_at, parcel_given_at].compact.min

    self.product = existing_product_in_storage unless no_fusing || storage.blank?

    self.product ||= variant.create_product(product_params)

    return false, self.product.errors if self.product.errors.any?
    true
  end

  def check_outgoing(_checked_at)
    update! product: source_product
  end

  def give_incoming
    check_incoming(parcel_prepared_at)
    ProductMovement.create!(product: product, delta: population, started_at: parcel_given_at, originator: self) unless product_is_unitary?
    ProductLocalization.create!(product: product, nature: :interior, container: storage, started_at: parcel_given_at, originator: self)
    ProductEnjoyment.create!(product: product, enjoyer: Entity.of_company, nature: :own, started_at: parcel_given_at, originator: self)
    ProductOwnership.create!(product: product, owner: Entity.of_company, nature: :own, started_at: parcel_given_at, originator: self) unless parcel_remain_owner
  end

  def give_outgoing
    if self.population == source_product.population(at: parcel_given_at) && !parcel_remain_owner
      ProductOwnership.create!(product: product, owner: parcel_recipient, started_at: parcel_given_at, originator: self)
      ProductLocalization.create!(product: product, nature: :exterior, started_at: parcel_given_at, originator: self)
      ProductEnjoyment.create!(product: product, enjoyer: parcel_recipient, nature: :other, started_at: parcel_given_at, originator: self)
    end
    ProductMovement.create!(product: product, delta: -1 * population, started_at: parcel_given_at, originator: self)
  end

  def existing_product_in_storage
    similar_products = Product.where(variant: variant)
    product_in_storage = similar_products.find do |p|
      location = p.localizations.last.container
      owner = p.owner
      location == storage && owner = Entity.of_company
    end
    product_in_storage
  end
end
