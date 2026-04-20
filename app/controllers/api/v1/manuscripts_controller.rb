module Api
  module V1
    class ManuscriptsController < BaseController
      # GET /api/v1/manuscripts
      # GET /api/v1/manuscripts?family=alexandrian
      def index
        base = Manuscript.ordered
        base = base.where(family: params[:family]) if params[:family].present?

        limit = [[params.fetch(:limit, 50).to_i, 1].max, 200].min
        page  = [params.fetch(:page, 1).to_i, 1].max
        offset = (page - 1) * limit

        total = base.count
        manuscripts = base.offset(offset).limit(limit)

        render json: {
          count: total,
          page: page,
          per_page: limit,
          total_pages: (total.to_f / limit).ceil,
          results: manuscripts.map { |ms| manuscript_json(ms) }
        }
      end

      # GET /api/v1/manuscripts/:siglum
      def show
        ms = Manuscript.find_by!(siglum: params[:siglum])
        render json: manuscript_json(ms)
      end

      private

      def manuscript_json(ms)
        {
          siglum: ms.siglum,
          name: ms.name,
          gregory_aland_number: ms.gregory_aland_number,
          intf_liste_number: ms.intf_liste_number,
          family: ms.family,
          language: ms.language,
          date_text: ms.date_text,
          date_year_estimate: ms.date_year_estimate,
          material: ms.material,
          format: ms.format,
          extent_description: ms.extent_description,
          shelfmark: ms.shelfmark,
          location: ms.location,
          lacunae: ms.lacunae
        }
      end
    end
  end
end
