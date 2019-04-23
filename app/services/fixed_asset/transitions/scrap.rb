class FixedAsset
  module Transitions
    class Scrap < Transitionable::Transition
      event :scrap
      from :in_use
      to :scrapped

      def initialize(fixed_asset, scrapped_on: Date.today)
        super fixed_asset
        @scrapped_on = scrapped_on
      end

      def transition
        resource.scrapped_on ||= @scrapped_on
        resource.state = :scrapped
        resource.transaction do
          resource.save!
          update_depreciation_out_on! resource.scrapped_on
          true
        end
      rescue
        false
      end

      private

        def update_depreciation_out_on!(out_on)
          depreciation_out_on = resource.current_depreciation(out_on)
          return false if depreciation_out_on.nil?

          # check if depreciation have journal_entry
          if depreciation_out_on.journal_entry
            raise StandardError, "This fixed asset depreciation is already bookkeep ( Entry : #{depreciation_out_on.journal_entry.number})"
          end

          next_depreciations = @fixed_asset.depreciations.where('position > ?', depreciation_out_on.position)

          # check if next depreciations have journal_entry
          if next_depreciations.any?(&:journal_entry)
            raise StandardError, "The next fixed assets depreciations are already bookkeep ( Entry : #{d.journal_entry.number})"
          end

          # stop bookkeeping next depreciations
          next_depreciations.update_all(accountable: false, locked: true)

          # use amount to last bookkeep (net_book_value == current_depreciation.depreciable_amount)
          # use amount to last bookkeep (already_depreciated_value == current_depreciation.depreciated_amount)

          # compute part time

          first_period = out_on.day
          global_period = (depreciation_out_on.stopped_on - depreciation_out_on.started_on) + 1
          first_ratio = (first_period.to_f / global_period.to_f) if global_period
          # second_ratio = (1 - first_ratio)

          first_depreciation_amount_ratio = (depreciation_out_on.amount * first_ratio).round(2)
          # second_depreciation_amount_ratio = (depreciation_out_on.amount * second_ratio).round(2)

          # update current_depreciation with new value and bookkeep it
          depreciation_out_on.stopped_on = out_on
          depreciation_out_on.amount = first_depreciation_amount_ratio
          depreciation_out_on.accountable = true
          depreciation_out_on.save!
        end
    end
  end
end
