# frozen_string_literal: true

module MyExtensions
  module ElectricalCalculator

    # Tool that draws green highlight overlay on entities via view.draw
    class HighlightTool
      def initialize(entities, duration = 2.0)
        @entities = entities
        @fill_color = Sketchup::Color.new(0, 220, 0, 80)
        @edge_color = Sketchup::Color.new(0, 255, 0, 255)
        @duration = duration
        @bounds = Geom::BoundingBox.new
        @entities.each { |e| @bounds.add(e.bounds) if e.valid? && e.respond_to?(:bounds) }
      end

      def activate
        Sketchup.active_model.active_view.invalidate
        UI.start_timer(@duration, false) do
          Sketchup.active_model.select_tool(nil)
        end
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        view.invalidate
      end

      def getExtents
        @bounds
      end

      def draw(view)
        view.line_stipple = ''
        @entities.each do |entity|
          next unless entity.valid?
          if entity.respond_to?(:bounds)
            draw_bounds(view, entity.bounds)
          end
          if entity.respond_to?(:definition)
            draw_instance_edges(view, entity)
          elsif entity.is_a?(Sketchup::Face)
            draw_face(view, entity)
          elsif entity.is_a?(Sketchup::Edge)
            draw_edge(view, entity)
          end
        end
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end

      private

      def draw_face(view, face)
        pts = face.outer_loop.vertices.map(&:position)
        view.drawing_color = @fill_color
        view.draw(GL_POLYGON, pts)
        view.line_width = 2
        view.drawing_color = @edge_color
        view.draw(GL_LINE_LOOP, pts)
      end

      def draw_edge(view, edge)
        view.line_width = 3
        view.drawing_color = @edge_color
        view.draw(GL_LINES, edge.vertices.map(&:position))
      end

      def draw_instance_edges(view, inst)
        tr = inst.transformation
        collect_edges_recursive(inst.definition.entities).each do |edge_pts|
          pts = edge_pts.map { |pt| pt.transform(tr) }
          view.line_width = 3
          view.drawing_color = @edge_color
          view.draw(GL_LINES, pts)
        end
      end

      def collect_edges_recursive(entities)
        edges = []
        entities.each do |ent|
          if ent.is_a?(Sketchup::Edge)
            edges << ent.vertices.map(&:position)
          elsif ent.is_a?(Sketchup::Group)
            sub_tr = ent.transformation
            collect_edges_recursive(ent.entities).each do |pts|
              edges << pts.map { |pt| pt.transform(sub_tr) }
            end
          elsif ent.is_a?(Sketchup::ComponentInstance)
            sub_tr = ent.transformation
            collect_edges_recursive(ent.definition.entities).each do |pts|
              edges << pts.map { |pt| pt.transform(sub_tr) }
            end
          end
        end
        edges
      end

      def draw_bounds(view, bb)
        return if bb.empty?
        pts = (0..7).map { |i| bb.corner(i) }
        bottom = [pts[0], pts[1], pts[3], pts[2]]
        top    = [pts[4], pts[5], pts[7], pts[6]]

        view.drawing_color = @fill_color
        view.draw(GL_QUADS, bottom)
        view.draw(GL_QUADS, top)
        # Side faces
        sides = [
          [pts[0], pts[1], pts[5], pts[4]],
          [pts[1], pts[3], pts[7], pts[5]],
          [pts[3], pts[2], pts[6], pts[7]],
          [pts[2], pts[0], pts[4], pts[6]]
        ]
        sides.each { |quad| view.draw(GL_QUADS, quad) }

        view.line_width = 2
        view.drawing_color = @edge_color
        view.draw(GL_LINE_LOOP, bottom)
        view.draw(GL_LINE_LOOP, top)
        4.times { |i| view.draw(GL_LINES, [pts[i], pts[i + 4]]) }
      end
    end

    module UILogic
      @last_pos = nil
      @assign_load_dialog = nil

      def self.prompt_set_load
        selection = Sketchup.active_model.selection
        return UI.messagebox('กรุณาเลือกวัตถุอย่างน้อย 1 ชิ้น') if selection.empty?

        if @assign_load_dialog
          @assign_load_dialog.bring_to_front
          return
        end
        
        # Create dialog
        dialog = UI::HtmlDialog.new({
          dialog_title: "Assign Electrical Load",
          scrollable: false,
          resizable: true,
          width: 500,
          height: 300,
          style: UI::HtmlDialog::STYLE_DIALOG
        })

        html_path = File.join(EXTENSION_ROOT, 'html', 'assign_load.html')
        dialog.set_file(html_path)
        if @last_pos
          dialog.set_position(@last_pos[0], @last_pos[1])
        else
          dialog.set_position(70, 115)
        end

        # --- Callbacks ---
        dialog.add_action_callback("applyLoad") do |_action_context, watts, load_type|
          Sketchup.active_model.start_operation('Set Load', true)
          selection.each { |entity| AttributesManager.set_load_attributes(entity, watts, load_type) }
          Sketchup.active_model.commit_operation

          # Keep reference to entities, clear selection, then draw green overlay
          applied_entities = selection.to_a
          selection.clear

          # Defer select_tool to main thread (HtmlDialog callback safety)
          UI.start_timer(0, false) do
            tool = HighlightTool.new(applied_entities, 3.0)
            Sketchup.active_model.select_tool(tool)
          end
        end

        dialog.add_action_callback("savePosition") do |_action_context, x, y|
          @last_pos = [x.to_i, y.to_i]
        end

        dialog.add_action_callback("closeDialog") do |_action_context|
          dialog.close
        end

        dialog.set_on_closed { @assign_load_dialog = nil }
        @assign_load_dialog = dialog
        dialog.show
      end
    end
  end
end
