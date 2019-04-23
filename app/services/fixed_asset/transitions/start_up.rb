class FixedAsset
  module Transitions
    class StartUp < Transitionable::Transition
      event :start_up
      from :draft
      to :in_use

      def initialize(fixed_asset)
        super fixed_asset
      end

      def transition
        resource.state = :in_use
        resource.transaction do
          resource.save!
          depreciate_imported_depreciations!
        end
        true
      rescue
        false
      end

      def can_run?
        super && resource.on_unclosed_periods?
      end

      private

        def depreciate_imported_depreciations!
          resource.depreciations.up_to(FinancialYear.opened.first.started_on).map { |fad| fad.update!(accountable: true) }
        end
    end
  end
end