# frozen_string_literal: true

require 'json'

module MyExtensions
  module ElectricalCalculator

    # =========================================================
    # PlaceDeviceTool — Custom SketchUp Tool for interactive
    # device placement with inference point snapping.
    # =========================================================
    class PlaceDeviceTool

      DICT_DEVICE = 'SU_Electrical_Device'.freeze

      def initialize(comp_def, label, conn_type, skp_file, dialog = nil)
        @comp_def = comp_def
        @label = label
        @conn_type = conn_type
        @skp_file = skp_file
        @dialog = dialog
        @rot_x = 0
        @rot_y = 0
        @rot_z = 0
        @shift_held = false
        @input_point = nil
        @position = ORIGIN
        @placed_count = 0
        # Axis locking
        @lock_axis = :none   # :none, :x, :y, :z
        @lock_origin = nil   # Point3d where lock was engaged
        # Offset from Component Axis (persisted via Sketchup defaults)
        @offset_x = Sketchup.read_default('SKH_PlaceDevice', 'OffsetX', 0.0).to_f
        @offset_y = Sketchup.read_default('SKH_PlaceDevice', 'OffsetY', 0.0).to_f
        @offset_z = Sketchup.read_default('SKH_PlaceDevice', 'OffsetZ', 0.0).to_f
        @offset_mode = false  # true when waiting for VCB offset input
        @last_ctrl_time = 0.0  # debounce for Ctrl toggle
        # Z-Plane: load last used value from preferences.
        # Always store/read as String to avoid SketchUp read_default type mismatch.
        saved_z = Sketchup.read_default('SKH_PlaceDevice', 'ZPlaneHeight', '')
        @z_plane_height = (saved_z.is_a?(String) && saved_z.strip != '') ? saved_z.to_f : (saved_z.is_a?(Numeric) ? saved_z.to_f : nil)
        # Copy Array state
        @array_enabled = false  # Toggle with Tab
        @array_start_pos = nil
        @array_end_pos = nil
        @array_base_instance = nil
        @array_base_erased = false
        @array_extra_instances = []
        @array_ready = false
      end

      def activate
        @input_point = Sketchup::InputPoint.new
        update_status_text
        update_vcb_label
        notify_dialog_offset
        Sketchup.active_model.active_view.invalidate
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        update_status_text
        view.invalidate
      end

      def onSetCursor
        cursor_id = UI.create_cursor(
          File.join(EXTENSION_ROOT, 'images', 'input_devices_icon.png'), 0, 0
        ) rescue 0
        UI.set_cursor(cursor_id > 0 ? cursor_id : 0)
      end

      def onMouseMove(flags, x, y, view)
        @input_point.pick(view, x, y)
        raw_pos = @input_point.position

        if @z_plane_mode
          # Preview Z-Plane height
          @z_plane_preview_h = raw_pos.z
          Sketchup.status_text = "Select Z-Plane: Height = #{@z_plane_preview_h.to_l} (Click to Set)"
          @position = raw_pos # Show cursor at picked point
          view.invalidate
          return
        end

        # Apply Z-Plane constraint if set
        base_pos = raw_pos
        if @z_plane_height
          # Snap reference at Z = 0 ground plane for XY inference, then place
          # at Z-Plane height. This lets the user align to geometry on the
          # ground plane while the component is placed at the desired height.
          z_tol = 0.1  # tolerance in inches (~2.5 mm)
          if raw_pos.z.abs < z_tol
            # InputPoint snapped near Z = 0 ground plane — use its XY, apply Z-Plane height
            base_pos = Geom::Point3d.new(raw_pos.x, raw_pos.y, @z_plane_height)
          else
            # Free space — project mouse ray onto Z = 0 ground plane for XY, then apply Z-Plane height
            ground_plane = [ORIGIN, Z_AXIS]
            ray = view.pickray(x, y)
            pt = Geom.intersect_line_plane(ray, ground_plane)
            base_pos = pt ? Geom::Point3d.new(pt.x, pt.y, @z_plane_height) : Geom::Point3d.new(raw_pos.x, raw_pos.y, @z_plane_height)
          end
        end

        # Apply axis lock constraint
        if @lock_axis != :none && @lock_origin
          case @lock_axis
          when :x
            @position = Geom::Point3d.new(base_pos.x, @lock_origin.y, @lock_origin.z)
          when :y
            @position = Geom::Point3d.new(@lock_origin.x, base_pos.y, @lock_origin.z)
          when :z
            # For Z-axis, use Plane Intersection (Plane facing camera)
            # This allows dragging vertically in 3D perspective
            normal = view.camera.direction.clone
            normal.z = 0
            if normal.length > 0.001
              normal.normalize!
              plane = [@lock_origin, normal]
              ray = view.pickray(x, y)
              pt = Geom.intersect_line_plane(ray, plane)
              if pt
                @position = Geom::Point3d.new(@lock_origin.x, @lock_origin.y, pt.z)
              end
            else
              # Fallback for Top View (looking straight down)
              # Z cannot change easily with mouse in 2D Top View
            end
          end
        else
          @position = base_pos
        end

        # Update VCB with distance when axis is locked (like native Move tool)
        if @lock_axis != :none && @lock_origin && !@offset_mode
          dist = @lock_origin.distance(@position)
          Sketchup.vcb_label = "Distance:"
          Sketchup.vcb_value = dist.to_l.to_s
        end

        view.tooltip = @input_point.tooltip if @input_point.valid?
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        return unless @input_point.valid?

        if @z_plane_mode
           # Set Z-Plane
           @z_plane_height = @input_point.position.z
           Sketchup.write_default('SKH_PlaceDevice', 'ZPlaneHeight', @z_plane_height.to_f.to_s)
           @z_plane_mode = false
           update_status_text
           view.invalidate
           return
        end

        instance = place_component(view)
        @placed_count += 1

        # Track positions for Copy Array (only when enabled)
        if @array_enabled
          if @array_ready
            # Reset for new sequence after array was ready
            @array_start_pos = @position.clone
            @array_end_pos = nil
            @array_base_instance = nil
            @array_base_erased = false
            @array_extra_instances = []
            @array_ready = false
          elsif @array_start_pos
            # Second click — array is ready
            @array_end_pos = @position.clone
            @array_base_instance = instance
            @array_base_erased = false
            @array_extra_instances = []
            @array_ready = true
          else
            # First click
            @array_start_pos = @position.clone
          end
        end

        if @dialog
          escaped = @label.gsub("'", "\\\\'")
          @dialog.execute_script("onDevicePlaced('#{escaped}')")
        end
        update_status_text
        update_vcb_label
        view.invalidate
      end

      def enableVCB?; true; end

      def onUserText(text, view)
        if @offset_mode
          # Offset mode: parse VCB input (X=val, Y=val, number=Z, or X,Y,Z)
          process_offset_input(text.strip, view)
        elsif @array_ready && text.strip =~ /\A[*xX]\s*(\d+)\z/
          n = $1.to_i
          if n >= 2
            apply_array_external(n, view)
          else
            UI.beep
            Sketchup.status_text = "Array: ต้องระบุจำนวน >= 2"
          end
        elsif @array_ready && text.strip =~ /\A\/\s*(\d+)\z/
          n = $1.to_i
          if n >= 2
            apply_array_divide(n, view)
          else
            UI.beep
            Sketchup.status_text = "Divide: ต้องระบุจำนวน >= 2"
          end
        elsif @lock_axis != :none && @lock_origin
          # Parse distance for axis-locked placement (like native Move)
          begin
            typed_dist = text.to_l
            dir = case @lock_axis
              when :x then X_AXIS
              when :y then Y_AXIS
              when :z then Z_AXIS
            end
            # Determine direction sign from current mouse position
            current_offset = case @lock_axis
              when :x then @position.x - @lock_origin.x
              when :y then @position.y - @lock_origin.y
              when :z then @position.z - @lock_origin.z
            end
            sign = current_offset >= 0 ? 1.0 : -1.0
            @position = @lock_origin.offset(dir, typed_dist.to_f * sign)
            place_component(view)
            @placed_count += 1
            if @dialog
              escaped = @label.gsub("'", "\\\\'")
              @dialog.execute_script("onDevicePlaced('#{escaped}')")
            end
            update_status_text
            update_vcb_label
            view.invalidate
          rescue ArgumentError
            UI.beep
            Sketchup.status_text = "Invalid distance value"
          end
        else
          # Parse length for Z-Plane
          begin
            length = text.to_l
            @z_plane_height = length
            Sketchup.write_default('SKH_PlaceDevice', 'ZPlaneHeight', @z_plane_height.to_f.to_s)
            @z_plane_mode = false
            Sketchup.status_text = "Z-Plane Set: #{length}"
            view.invalidate
          rescue ArgumentError
            UI.beep
            Sketchup.status_text = "Invalid length entered"
          end
        end
      end

      # Use explicit key codes to avoid constant conflicts
      KEY_LEFT  = 37
      KEY_UP    = 38
      KEY_RIGHT = 39
      KEY_DOWN  = 40
      KEY_SHIFT = 16


      def onKeyDown(key, repeat, flags, view)
        @z_plane_mode ||= false

        begin
          case key
          when 9 # Tab — Toggle Copy Array
            @array_enabled = !@array_enabled
            if !@array_enabled
              # Turning off: reset array state
              @array_ready = false
              @array_start_pos = nil
              @array_end_pos = nil
              @array_base_instance = nil
              @array_base_erased = false
              @array_extra_instances = []
            end
            update_status_text
            update_vcb_label
            view.invalidate
            return true
          when 17 # Ctrl (VK_CONTROL) — debounce to prevent rapid toggle
            now = Time.now.to_f
            if (now - @last_ctrl_time) > 0.3
              @offset_mode = !@offset_mode
              if @offset_mode
                Sketchup.status_text = "Offset Mode: พิมพ์ X,Y,Z (เช่น 100mm,50mm,0) หรือ X=val / Y=val / ตัวเลข=Z แล้วกด Enter | Esc=ยกเลิก"
                Sketchup.vcb_label = "Offset X,Y,Z:"
                Sketchup.vcb_value = "#{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}"
              else
                update_status_text
                update_vcb_label
              end
              view.invalidate
            end
            @last_ctrl_time = now
            return true
          when 18 # Alt (VK_MENU)
            @z_plane_mode = !@z_plane_mode
            if @z_plane_mode
               Sketchup.status_text = "Select Z-Plane Reference: Click point or Type Height (VCB)"
            else
               update_status_text
            end
            view.invalidate
            return true
          when 27 # Escape (VK_ESCAPE)
            if @offset_mode
              @offset_mode = false
              update_status_text
              update_vcb_label
              view.invalidate
              return true
            elsif @z_plane_mode
              @z_plane_mode = false
              update_status_text
              view.invalidate
              return true
            elsif @array_ready
              @array_ready = false
              @array_start_pos = nil
              @array_end_pos = nil
              @array_base_instance = nil
              @array_base_erased = false
              @array_extra_instances = []
              update_status_text
              update_vcb_label
              view.invalidate
              return true
            elsif @lock_axis != :none
              Sketchup.status_text = "Debug: Clearing Lock"
              @lock_axis = :none
              @lock_origin = nil
              update_status_text
              view.invalidate
            else
              Sketchup.active_model.select_tool(nil)
            end
            return true
          when 16  # Shift
            @shift_held = true
            return true
          when 39  # Right (KEY_RIGHT)
            if @shift_held  # Shift held → rotate around X axis
              @rot_x = (@rot_x + 90) % 360
              update_status_text
              view.invalidate
            else
              toggle_axis_lock(:x, view)
            end
            return true
          when 37  # Left (KEY_LEFT)
            if @shift_held  # Shift held → rotate around Y axis
              @rot_y = (@rot_y + 90) % 360
              update_status_text
              view.invalidate
            else
              toggle_axis_lock(:y, view)
            end
            return true
          when 38  # Up (KEY_UP)
            if @shift_held  # Shift held → rotate around Z axis
              @rot_z = (@rot_z + 90) % 360
              update_status_text
              view.invalidate
            else
              toggle_axis_lock(:z, view)
            end
            return true
          end
        rescue => e
          Sketchup.status_text = "Error in onKeyDown: #{e.message}"
          puts e.backtrace
        end
        false
      end

      def onKeyUp(key, repeat, flags, view)
        if key == 16  # Shift released
          @shift_held = false
        end
        false
      end

      def draw(view)
        return unless @input_point && @input_point.valid?
        @input_point.draw(view)
        draw_preview(view)
        draw_axis_lock_indicator(view) if @lock_axis != :none && @lock_origin
        draw_offset_indicator(view) if @offset_x != 0 || @offset_y != 0 || @offset_z != 0
        draw_z_plane_indicator(view) if @z_plane_height && !@z_plane_mode
        draw_array_indicator(view) if @array_ready
      end

      def getExtents
        bb = Geom::BoundingBox.new
        if @comp_def && @position
          comp_bb = @comp_def.bounds
          transform = build_transform(@position)
          8.times { |i| bb.add(comp_bb.corner(i).transform(transform)) }
        end
        bb
      end

      private

      def build_transform(point)
        # Offset is applied in component local space (relative to component axes)
        offset = Geom::Transformation.new([@offset_x, @offset_y, @offset_z])
        move = Geom::Transformation.new(point)
        move * rotation_transform * offset
      end

      def rotation_transform
        rx = Geom::Transformation.rotation(ORIGIN, X_AXIS, @rot_x.degrees)
        ry = Geom::Transformation.rotation(ORIGIN, Y_AXIS, @rot_y.degrees)
        rz = Geom::Transformation.rotation(ORIGIN, Z_AXIS, @rot_z.degrees)
        rz * ry * rx
      end

      def toggle_axis_lock(axis, view)
        Sketchup.status_text = "Debug: Toggling Lock #{axis}"
        if @lock_axis == axis
          # Toggle off
          @lock_axis = :none
          @lock_origin = nil
        else
          # Lock to this axis
          @lock_axis = axis
          @position ||= ORIGIN
          @lock_origin = @position.clone
        end
        update_status_text
        view.invalidate
      end

      def draw_offset_indicator(view)
        return unless @position
        # Draw small axis cross at the offset origin (component axis)
        origin_pt = Geom::Point3d.new(@offset_x, @offset_y, @offset_z).transform(rotation_transform).transform(Geom::Transformation.new(@position))
        sp = view.screen_coords(origin_pt)
        sp0 = view.screen_coords(@position)

        # Draw dashed line from click point to offset component origin
        view.line_stipple = '.'
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(255, 140, 0, 200)
        view.draw2d(GL_LINES, [[sp0.x, sp0.y, 0], [sp.x, sp.y, 0]])

        # Draw small diamond at offset origin
        d = 5
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(255, 140, 0, 255)
        view.draw2d(GL_LINE_LOOP, [
          [sp.x, sp.y - d, 0], [sp.x + d, sp.y, 0],
          [sp.x, sp.y + d, 0], [sp.x - d, sp.y, 0]
        ])

        # Draw offset text
        view.draw_text([sp.x + 8, sp.y - 12, 0],
          "Offset: #{@offset_x.to_l}, #{@offset_y.to_l}, #{@offset_z.to_l}",
          size: 10, color: Sketchup::Color.new(255, 140, 0))
      end

      def draw_z_plane_indicator(view)
        return unless @position
        # Vertical dashed line from ground (Z=0) to the Z-plane position
        ground_pt = Geom::Point3d.new(@position.x, @position.y, 0)
        z_pt      = Geom::Point3d.new(@position.x, @position.y, @z_plane_height)
        view.line_stipple = '-.-'
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(0, 100, 255, 180)
        view.draw(GL_LINES, [ground_pt, z_pt])

        # Z-plane height label
        sp = view.screen_coords(z_pt)
        view.line_stipple = ''
        view.draw_text([sp.x + 10, sp.y - 6, 0],
          "Z: #{@z_plane_height.to_l}",
          size: 10, color: Sketchup::Color.new(0, 100, 255))
      end

      def draw_axis_lock_indicator(view)
        return unless @lock_origin
        color, dir = case @lock_axis
          when :x then [Sketchup::Color.new(255, 0, 0, 180), X_AXIS]
          when :y then [Sketchup::Color.new(0, 180, 0, 180), Y_AXIS]
          when :z then [Sketchup::Color.new(0, 0, 255, 180), Z_AXIS]
          else return
        end
        len = 10000  # long enough line
        pt1 = @lock_origin.offset(dir, -len)
        pt2 = @lock_origin.offset(dir,  len)
        view.line_stipple = '-'
        view.line_width = 2
        view.drawing_color = color
        view.draw(GL_LINES, [pt1, pt2])

        # Draw solid distance line from lock_origin to current position
        if @position
          view.line_stipple = ''
          view.line_width = 3
          view.drawing_color = color
          view.draw(GL_LINES, [@lock_origin, @position])

          # Distance text at midpoint (like native Move tool)
          dist = @lock_origin.distance(@position)
          if dist > 0.001
            mid = Geom::Point3d.linear_combination(0.5, @lock_origin, 0.5, @position)
            sp_mid = view.screen_coords(mid)
            axis_name = case @lock_axis
              when :x then "Red (X)"
              when :y then "Green (Y)"
              when :z then "Blue (Z)"
            end
            view.draw_text([sp_mid.x + 12, sp_mid.y - 14, 0],
              dist.to_l.to_s,
              size: 12, bold: true, color: color)
            view.draw_text([sp_mid.x + 12, sp_mid.y + 2, 0],
              "Lock: #{axis_name}",
              size: 9, color: color)
          end

          # Draw small square marker at lock_origin
          sp_origin = view.screen_coords(@lock_origin)
          d = 5
          view.line_stipple = ''
          view.line_width = 2
          view.drawing_color = color
          view.draw2d(GL_LINE_LOOP, [
            [sp_origin.x - d, sp_origin.y - d, 0], [sp_origin.x + d, sp_origin.y - d, 0],
            [sp_origin.x + d, sp_origin.y + d, 0], [sp_origin.x - d, sp_origin.y + d, 0]
          ])
        end
        view.line_stipple = ''
      end

      def place_component(view)
        model = Sketchup.active_model
        model.start_operation('Place Device', true)
        transform = build_transform(@position)
        instance = model.active_entities.add_instance(@comp_def, transform)
        instance.set_attribute(DICT_DEVICE, 'device_label', @label)
        instance.set_attribute(DICT_DEVICE, 'device_type', @conn_type)
        instance.set_attribute(DICT_DEVICE, 'skp_file', @skp_file)
        model.commit_operation
        instance
      end

      def draw_preview(view)
        transform = build_transform(@position)

        # --- Draw actual component shape (edges + faces) ---
        # Draw semi-transparent faces
        view.drawing_color = Sketchup::Color.new(0, 120, 215, 50)
        collect_entities_recursive(@comp_def.entities, transform) do |entity, xform|
          if entity.is_a?(Sketchup::Face)
            pts = entity.outer_loop.vertices.map { |v| v.position.transform(xform) }
            view.draw(GL_POLYGON, pts) if pts.length >= 3
          end
        end

        # Draw edges (wireframe)
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(0, 120, 215, 180)
        collect_entities_recursive(@comp_def.entities, transform) do |entity, xform|
          if entity.is_a?(Sketchup::Edge)
            pt1 = entity.start.position.transform(xform)
            pt2 = entity.end.position.transform(xform)
            view.draw(GL_LINES, [pt1, pt2])
          end
        end

        # Crosshair (reduced 50%)
        view.line_stipple = ''
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(255, 0, 0, 200)
        s = 25
        sp = view.screen_coords(@position)
        view.draw2d(GL_LINES, [
          [sp.x - s, sp.y, 0], [sp.x + s, sp.y, 0],
          [sp.x, sp.y - s, 0], [sp.x, sp.y + s, 0]
        ])
      end

      # Recursively iterate entities, descending into groups/components
      def collect_entities_recursive(entities, parent_transform, &block)
        entities.each do |entity|
          case entity
          when Sketchup::Group
            combined = parent_transform * entity.transformation
            collect_entities_recursive(entity.entities, combined, &block)
          when Sketchup::ComponentInstance
            combined = parent_transform * entity.transformation
            collect_entities_recursive(entity.definition.entities, combined, &block)
          else
            block.call(entity, parent_transform)
          end
        end
      end

      def update_status_text
        lock_info = case @lock_axis
          when :x then " | \u{1F512} Lock X (Red)"
          when :y then " | \u{1F512} Lock Y (Green)"
          when :z then " | \u{1F512} Lock Z (Blue)"
          else ''
        end
        z_info = @z_plane_height ? " | Z-Plane: #{@z_plane_height.to_l}" : ""
        has_offset = (@offset_x != 0 || @offset_y != 0 || @offset_z != 0)
        offset_info = has_offset ? " | Offset: #{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}" : ""
        rot_info = rotation_info_str
        array_toggle = @array_enabled ? " | 📋 Array: ON" : ""
        array_info = @array_ready ? " | พิมพ์ *n=Copy /n=Divide ใน VCB" : ""
        Sketchup.status_text = "วางอุปกรณ์: #{@label}#{z_info}#{offset_info}#{rot_info}#{array_toggle}#{array_info} | Tab=Toggle Array | Ctrl=Offset | Alt=Z-Plane | Shift+←=หมุนY Shift+→=หมุนX Shift+↑=หมุนZ | Click=วาง | Esc=ยกเลิก#{lock_info}"
      end

      def update_vcb_label
        if @offset_mode
          Sketchup.vcb_label = "Offset X,Y,Z:"
          Sketchup.vcb_value = "#{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}"
        elsif @lock_axis != :none && @lock_origin && @position
          dist = @lock_origin.distance(@position)
          Sketchup.vcb_label = "Distance:"
          Sketchup.vcb_value = dist.to_l.to_s
        elsif @array_ready && @array_start_pos && @array_end_pos
          dist = @array_start_pos.distance(@array_end_pos)
          Sketchup.vcb_label = "Array (*n /n):"
          Sketchup.vcb_value = dist.to_l.to_s
        elsif @z_plane_height
          Sketchup.vcb_label = "Z-Plane:"
          Sketchup.vcb_value = @z_plane_height.to_l.to_s
        elsif @offset_x != 0 || @offset_y != 0 || @offset_z != 0
          Sketchup.vcb_label = "Offset:"
          Sketchup.vcb_value = "#{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}"
        else
          Sketchup.vcb_label = "Z-Plane:"
          Sketchup.vcb_value = ""
        end
      end

      def rotation_info_str
        parts = []
        parts << "X:#{@rot_x}°" if @rot_x != 0
        parts << "Y:#{@rot_y}°" if @rot_y != 0
        parts << "Z:#{@rot_z}°" if @rot_z != 0
        parts.empty? ? "" : " | หมุน: #{parts.join(' ')}"
      end

      def save_offsets
        Sketchup.write_default('SKH_PlaceDevice', 'OffsetX', @offset_x)
        Sketchup.write_default('SKH_PlaceDevice', 'OffsetY', @offset_y)
        Sketchup.write_default('SKH_PlaceDevice', 'OffsetZ', @offset_z)
      end

      # Offset parsing logic: X=val, Y=val, single number=Z, or X,Y,Z
      def process_offset_input(text, view)
        # Single-axis format: X=val, Y=val, Z=val (case-insensitive)
        if text =~ /\A([xyzXYZ])\s*=\s*(.+)\z/
          begin
            axis = $1.downcase
            val = $2.to_l.to_f
            case axis
            when 'x' then @offset_x = val
            when 'y' then @offset_y = val
            when 'z' then @offset_z = val
            end
            save_offsets
            @offset_mode = false
            update_status_text
            update_vcb_label
            notify_dialog_offset
            view.invalidate
          rescue ArgumentError
            UI.beep
            Sketchup.status_text = "Invalid value. Use: X=100mm or Y=0.5m or 0=Z"
          end
          return
        end
        # Multi-axis format: "X,Y,Z" or "X,Y" or "X;Y;Z" or single value
        begin
          parts = text.split(/[,;\s]+/)
          if parts.length >= 3
            @offset_x = parts[0].to_l.to_f
            @offset_y = parts[1].to_l.to_f
            @offset_z = parts[2].to_l.to_f
          elsif parts.length == 2
            @offset_x = parts[0].to_l.to_f
            @offset_y = parts[1].to_l.to_f
          elsif parts.length == 1
            @offset_z = parts[0].to_l.to_f
          else
            UI.beep
            Sketchup.status_text = "Invalid offset. Use: X,Y,Z (e.g. 100mm,50mm,0)"
            return
          end
          save_offsets
          @offset_mode = false
          update_status_text
          update_vcb_label
          notify_dialog_offset
          view.invalidate
        rescue ArgumentError
          UI.beep
          Sketchup.status_text = "Invalid offset value. Use: X,Y,Z (e.g. 100mm,50mm,0)"
        end
      end

      def notify_dialog_offset
        return unless @dialog
        @dialog.execute_script(
          "if(typeof onOffsetChanged==='function') onOffsetChanged('#{@offset_x.to_l}', '#{@offset_y.to_l}', '#{@offset_z.to_l}');"
        )
      end

      # -------------------------------------------------------
      # Copy Array: place instance at a specific position
      # -------------------------------------------------------
      def place_instance_at(pos)
        transform = build_transform(pos)
        instance = Sketchup.active_model.active_entities.add_instance(@comp_def, transform)
        instance.set_attribute(DICT_DEVICE, 'device_label', @label)
        instance.set_attribute(DICT_DEVICE, 'device_type', @conn_type)
        instance.set_attribute(DICT_DEVICE, 'skp_file', @skp_file)
        instance
      end

      # -------------------------------------------------------
      # Copy Array: erase previously created array instances
      # -------------------------------------------------------
      def erase_array_extras
        @array_extra_instances.each { |inst| inst.erase! if inst.valid? }
        @array_extra_instances = []
      end

      # -------------------------------------------------------
      # Copy Array External (*n / xn / Xn)
      # Places n-1 additional copies beyond point B at same
      # spacing as A→B. Re-entering replaces previous array.
      # -------------------------------------------------------
      def apply_array_external(n, view)
        return if !@array_start_pos || !@array_end_pos
        dist = @array_start_pos.distance(@array_end_pos)
        return if dist < 0.001

        model = Sketchup.active_model
        model.start_operation('Copy Array *' + n.to_s, true)
        begin
          erased_count = @array_extra_instances.count { |i| i.valid? }
          erase_array_extras
          @placed_count -= erased_count

          # Restore base instance at B if it was erased by previous divide
          if @array_base_erased
            @array_base_instance = place_instance_at(@array_end_pos)
            @array_base_erased = false
            @placed_count += 1
          end

          dir = Geom::Vector3d.new(
            @array_end_pos.x - @array_start_pos.x,
            @array_end_pos.y - @array_start_pos.y,
            @array_end_pos.z - @array_start_pos.z
          )

          (1...n).each do |i|
            pos = Geom::Point3d.new(
              @array_end_pos.x + dir.x * i,
              @array_end_pos.y + dir.y * i,
              @array_end_pos.z + dir.z * i
            )
            @array_extra_instances << place_instance_at(pos)
          end

          @placed_count += (n - 1)
          model.commit_operation

          if @dialog
            escaped = @label.gsub("'", "\\\\'")
            (n - 1).times { @dialog.execute_script("onDevicePlaced('#{escaped}')") }
          end

          Sketchup.status_text = "Copy Array *#{n}: วาง #{n - 1} ตัวเพิ่ม (ทั้งหมด #{@placed_count}) | พิมพ์ *n /n เพื่อเปลี่ยน | Click=เริ่มใหม่"
          Sketchup.vcb_label = "Array (*n /n):"
          Sketchup.vcb_value = "*#{n}"
          view.invalidate
        rescue => e
          model.abort_operation
          Sketchup.status_text = "Copy Array error: #{e.message}"
        end
      end

      # -------------------------------------------------------
      # Divide Array (/n)
      # Erases device at B, then places n devices evenly
      # between A and B (A exclusive, B inclusive).
      # Re-entering replaces previous array.
      # -------------------------------------------------------
      def apply_array_divide(n, view)
        return if !@array_start_pos || !@array_end_pos
        dist = @array_start_pos.distance(@array_end_pos)
        return if dist < 0.001

        model = Sketchup.active_model
        model.start_operation('Divide Array /' + n.to_s, true)
        begin
          erased_count = @array_extra_instances.count { |i| i.valid? }
          erase_array_extras
          @placed_count -= erased_count

          # Erase base instance at B (will be replaced by evenly spaced copies)
          if !@array_base_erased && @array_base_instance && @array_base_instance.valid?
            @array_base_instance.erase!
            @array_base_erased = true
            @placed_count -= 1
          end

          dir = Geom::Vector3d.new(
            @array_end_pos.x - @array_start_pos.x,
            @array_end_pos.y - @array_start_pos.y,
            @array_end_pos.z - @array_start_pos.z
          )

          (1..n).each do |i|
            frac = i.to_f / n.to_f
            pos = Geom::Point3d.new(
              @array_start_pos.x + dir.x * frac,
              @array_start_pos.y + dir.y * frac,
              @array_start_pos.z + dir.z * frac
            )
            @array_extra_instances << place_instance_at(pos)
          end

          @placed_count += n
          model.commit_operation

          if @dialog
            escaped = @label.gsub("'", "\\\\'")
            n.times { @dialog.execute_script("onDevicePlaced('#{escaped}')") }
          end

          Sketchup.status_text = "Divide Array /#{n}: แบ่ง #{n} ตัวเท่าๆ กัน (ทั้งหมด #{@placed_count}) | พิมพ์ *n /n เพื่อเปลี่ยน | Click=เริ่มใหม่"
          Sketchup.vcb_label = "Array (*n /n):"
          Sketchup.vcb_value = "/#{n}"
          view.invalidate
        rescue => e
          model.abort_operation
          Sketchup.status_text = "Divide Array error: #{e.message}"
        end
      end

      # -------------------------------------------------------
      # Draw array direction indicator (A→B line + labels)
      # -------------------------------------------------------
      def draw_array_indicator(view)
        return unless @array_start_pos && @array_end_pos

        # Dashed line from A to B
        view.line_stipple = '-'
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(255, 140, 0, 200)
        view.draw(GL_LINES, [@array_start_pos, @array_end_pos])

        # Distance label at midpoint
        mid = Geom::Point3d.linear_combination(0.5, @array_start_pos, 0.5, @array_end_pos)
        sp = view.screen_coords(mid)
        dist = @array_start_pos.distance(@array_end_pos)
        view.line_stipple = ''
        view.draw_text([sp.x + 10, sp.y - 10, 0],
          "Array: #{dist.to_l} | VCB: *n or /n",
          size: 11, color: Sketchup::Color.new(255, 140, 0))

        # Square markers at A and B
        [[@array_start_pos, 'A'], [@array_end_pos, 'B']].each do |pt, lbl|
          spt = view.screen_coords(pt)
          d = 6
          view.line_width = 2
          view.drawing_color = Sketchup::Color.new(255, 140, 0, 255)
          view.draw2d(GL_LINE_LOOP, [
            [spt.x - d, spt.y - d, 0], [spt.x + d, spt.y - d, 0],
            [spt.x + d, spt.y + d, 0], [spt.x - d, spt.y + d, 0]
          ])
          view.draw_text([spt.x + 8, spt.y - 8, 0], lbl,
            size: 10, color: Sketchup::Color.new(255, 140, 0))
        end

        # Draw markers at array extra instance positions
        @array_extra_instances.each do |inst|
          next unless inst.valid?
          ipt = inst.transformation.origin
          sipt = view.screen_coords(ipt)
          d = 4
          view.drawing_color = Sketchup::Color.new(255, 140, 0, 150)
          view.draw2d(GL_LINE_LOOP, [
            [sipt.x - d, sipt.y - d, 0], [sipt.x + d, sipt.y - d, 0],
            [sipt.x + d, sipt.y + d, 0], [sipt.x - d, sipt.y + d, 0]
          ])
        end
      end
    end

    # =========================================================
    # DrawWiringTool — Custom SketchUp Tool for drawing wiring
    # arcs between two points.
    #
    # Features:
    #   - Click point 1 → Click point 2 → draws 2-point Arc
    #   - Arc radius = 1/2 of distance between the 2 points
    #   - Continuous mode: keeps drawing arcs until Space
    #   - Space bar = finish → group all arcs, name group & tag
    #   - Full inference engine for snapping
    #   - Esc = cancel current arc (if mid-draw) or finish tool
    # =========================================================
    class DrawWiringTool

      DICT_WIRE = 'SU_Electrical_Wire'.freeze
      ARC_SEGMENTS = 24  # number of segments for arc smoothness
      FILLET_ANGLE_TOL = 0.087  # ~5° tolerance for detecting 90° corners

      def initialize(wire_label, nb_wires, wire_section, dialog = nil)
        @wire_label = wire_label
        @nb_wires = nb_wires
        @wire_section = wire_section
        @dialog = dialog

        @input_point = nil
        @input_point2 = nil       # second input point for inference lock
        @current_pos = ORIGIN

        @state = :pick_start      # :pick_start or :pick_end
        @start_point = nil
        @arc_edges_all = []       # collect all arc edge arrays
        @arc_count = 0

        # Generate a unique color for this wire type
        @wire_color = generate_wire_color
        
        # Generate a unique color for this wire type
        @wire_color = generate_wire_color
        
        # Arc Direction: Normal (false) or Flipped (true)
        # Load from preferences, default to false
        @reverse_arc = Sketchup.read_default("SKH_Wiring", "ReverseArc", false)
        
        # Bulge Height Ratio (Denominator): 4.0, 6.0, or 8.0
        # Load from preferences, default to 4.0
        val = Sketchup.read_default("SKH_Wiring", "BulgeRatio", 4.0).to_f
        @bulge_denominator = [4.0, 6.0, 8.0].include?(val) ? val : 4.0

        # Line Mode: Toggle with Ctrl (false = Arc mode, true = Line mode)
        @line_mode = Sketchup.read_default("SKH_Wiring", "LineMode", false)
        @prev_line_dir = nil        # direction of previous line segment (for fillet detection)
        @prev_line_edges = []       # edges of previous line segment (for trimming at fillet)
        @prev_start_point = nil     # start point of previous line segment

        # Fillet Radius for 90° corners in line mode (user-configurable via VCB)
        fillet_val = Sketchup.read_default("SKH_Wiring", "FilletRadius", 60.0).to_f
        @fillet_radius = fillet_val.mm

        # Axis Lock: nil = free, :x = Red, :y = Green, :z = Blue
        @axis_lock = nil
        @shift_locked = false  # true when lock was set by Shift (hold-to-lock)
      end

      # --- Tool lifecycle ---

      def activate
        @input_point = Sketchup::InputPoint.new
        @input_point2 = Sketchup::InputPoint.new
        update_status_text
        update_vcb_label
        
        # Load style for color by material
        style_path = File.join(EXTENSION_ROOT, 'style', 'Color by Material.style')
        if File.exist?(style_path)
          styles = Sketchup.active_model.styles
          # Load and activate style
          styles.add_style(style_path, true)
        end
        
        # Force EdgeColorMode to ByMaterial (1) and disable overrides
        ro = Sketchup.active_model.rendering_options
        ro['EdgeColorMode'] = 0
        ro['DrawSilhouettes'] = false      # Disable Profiles (black lines)
        ro['DisplayColorByLayer'] = false  # Disable Color by Tag
        
        Sketchup.active_model.active_view.invalidate
      end

      def deactivate(view)
        # If we have drawn any arcs, group them on deactivate
        finish_and_group if @arc_count > 0
        view.invalidate
      end

      def resume(view)
        update_status_text
        view.invalidate
      end

      # --- Mouse events ---

      def onMouseMove(flags, x, y, view)
        if @state == :pick_start
          @input_point.pick(view, x, y)
        else
          # Lock inference relative to start point
          @input_point.pick(view, x, y, @input_point2)
        end
        @current_pos = @input_point.position

        # Apply axis lock constraint (project cursor onto locked axis from start point)
        if @axis_lock && @state == :pick_end && @start_point
          sp = @start_point
          cp = @current_pos
          case @axis_lock
          when :x
            @current_pos = Geom::Point3d.new(cp.x, sp.y, sp.z)
          when :y
            @current_pos = Geom::Point3d.new(sp.x, cp.y, sp.z)
          when :z
            @current_pos = Geom::Point3d.new(sp.x, sp.y, cp.z)
          end
        end

        view.tooltip = @input_point.tooltip if @input_point.valid?
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        return unless @input_point.valid?

        if @state == :pick_start
          # First click: set start point
          @start_point = @input_point.position.clone
          @input_point2.copy!(@input_point)  # save for inference lock
          @state = :pick_end
          update_status_text
          view.invalidate
        else
          # Second click: draw arc or line depending on mode
          # Use @current_pos which respects axis lock constraint
          end_point = @current_pos.clone
          if @line_mode
            draw_line_segment(@start_point, end_point)
          else
            draw_arc(@start_point, end_point)
          end
          @arc_count += 1

          # Notify dialog
          if @dialog
            escaped = @wire_label.gsub("'", "\\\\'")
            @dialog.execute_script("onWireArcDrawn('#{escaped}', #{@arc_count})")
          end

          # Auto-chain: end point becomes start of next arc
          @start_point = end_point
          @input_point2.copy!(@input_point)
          # Stay in :pick_end state — user just clicks next end point
          update_status_text
          view.invalidate
        end
      end

      # --- Keyboard events ---

      def onKeyDown(key, repeat, flags, view)
        case key
        when VK_TAB
          # Toggle Arc Direction
          @reverse_arc = !@reverse_arc
          # Save setting
          Sketchup.write_default("SKH_Wiring", "ReverseArc", @reverse_arc)
          update_status_text
          view.invalidate
        when 18 # VK_MENU (Alt)
          # Toggle Bulge Height Ratio: 4 -> 6 -> 8 -> 4
          if @bulge_denominator == 4.0
            @bulge_denominator = 6.0
          elsif @bulge_denominator == 6.0
            @bulge_denominator = 8.0
          else
            @bulge_denominator = 4.0
          end
          # Save setting
          Sketchup.write_default("SKH_Wiring", "BulgeRatio", @bulge_denominator)
          update_status_text
          view.invalidate
        when VK_CONTROL
          # Toggle Line Mode / Arc Mode
          @line_mode = !@line_mode
          Sketchup.write_default("SKH_Wiring", "LineMode", @line_mode)
          # Reset line tracking when toggling
          @prev_line_dir = nil
          @prev_line_edges = []
          @prev_start_point = nil
          @axis_lock = nil
          update_status_text
          update_vcb_label
          view.invalidate
        when VK_SHIFT
          # Hold Shift = auto-detect & lock nearest axis from current direction
          if @state == :pick_end && @start_point
            dir = @current_pos - @start_point
            ax = dir.x.abs
            ay = dir.y.abs
            az = dir.z.abs
            if ax >= ay && ax >= az
              @axis_lock = :x
            elsif ay >= ax && ay >= az
              @axis_lock = :y
            else
              @axis_lock = :z
            end
            @shift_locked = true
            update_status_text
            view.invalidate
          end
        when VK_RIGHT
          # Toggle Red (X) axis lock
          @axis_lock = (@axis_lock == :x) ? nil : :x
          @shift_locked = false
          update_status_text
          view.invalidate
        when VK_LEFT
          # Toggle Green (Y) axis lock
          @axis_lock = (@axis_lock == :y) ? nil : :y
          @shift_locked = false
          update_status_text
          view.invalidate
        when VK_UP
          # Toggle Blue (Z) axis lock
          @axis_lock = (@axis_lock == :z) ? nil : :z
          @shift_locked = false
          update_status_text
          view.invalidate
        when VK_DOWN
          # Unlock axis
          @axis_lock = nil
          @shift_locked = false
          update_status_text
          view.invalidate
        when VK_ESCAPE
          if @state == :pick_end
            # Cancel current arc, go back to pick_start
            @start_point = nil
            @prev_line_dir = nil
            @prev_line_edges = []
            @prev_start_point = nil
            @axis_lock = nil
            @state = :pick_start
            update_status_text
            view.invalidate
          else
            # Finish & exit tool
            Sketchup.active_model.select_tool(nil)
          end
        when VK_SPACE
          # Space = finish tool, group all arcs
          Sketchup.active_model.select_tool(nil)
        end
      end

      def onKeyUp(key, repeat, flags, view)
        if key == VK_SHIFT && @shift_locked
          @axis_lock = nil
          @shift_locked = false
          update_status_text
          view.invalidate
        end
      end

      # Return the space key constant
      def self.vk_space; 32; end
      # Return the space key constant
      def self.vk_space; 32; end
      VK_SPACE = 32
      VK_TAB = 9
      VK_CONTROL = 17
      VK_RIGHT = 39   # Lock Red (X)
      VK_LEFT  = 37   # Lock Green (Y)
      VK_UP    = 38   # Lock Blue (Z)
      VK_DOWN  = 40   # Unlock axis
      VK_SHIFT = 16   # Hold to lock inferred axis

      def enableVCB?; true; end

      def onUserText(text, view)
        if @line_mode
          # Parse fillet radius from VCB input
          begin
            val = text.to_l
            if val > 0
              @fillet_radius = val
              # Save as mm value to preferences
              Sketchup.write_default("SKH_Wiring", "FilletRadius", val.to_mm)
              update_status_text
              update_vcb_label
              view.invalidate
            else
              UI.beep
              Sketchup.status_text = "Fillet Radius ต้องมากกว่า 0"
            end
          rescue ArgumentError
            UI.beep
            Sketchup.status_text = "Invalid fillet radius value"
          end
        end
      end

      # --- Drawing (preview) ---

      def draw(view)
        return unless @input_point && @input_point.valid?

        # Draw inference point
        @input_point.draw(view)

        # If in pick_end state, draw preview from start to cursor
        if @state == :pick_end && @start_point
          # Draw axis lock indicator line
          if @axis_lock
            axis_color, axis_vec = case @axis_lock
              when :x then [Sketchup::Color.new(255, 0, 0, 120), X_AXIS]
              when :y then [Sketchup::Color.new(0, 180, 0, 120), Y_AXIS]
              when :z then [Sketchup::Color.new(0, 0, 255, 120), Z_AXIS]
            end
            ext = 100000  # long enough to appear infinite
            lock_pt1 = @start_point.offset(axis_vec, -ext)
            lock_pt2 = @start_point.offset(axis_vec, ext)
            view.line_stipple = '.'
            view.line_width = 1
            view.drawing_color = axis_color
            view.draw(GL_LINES, [lock_pt1, lock_pt2])
          end

          if @line_mode
            draw_line_preview(view, @start_point, @current_pos)
          else
            draw_arc_preview(view, @start_point, @current_pos)
          end
          draw_point_marker(view, @start_point, Sketchup::Color.new(0, 200, 80, 255))
        end

        # Draw cursor marker
        draw_point_marker(view, @current_pos, Sketchup::Color.new(255, 165, 0, 255))
      end

      def getExtents
        bb = Geom::BoundingBox.new
        bb.add(@current_pos) if @current_pos
        bb.add(@start_point) if @start_point
        bb
      end

      private

      # -------------------------------------------------------
      # Draw a straight line segment with automatic 90° fillet
      # When the angle between consecutive segments is ~90°,
      # a fillet arc (radius 60mm) is inserted at the corner.
      # -------------------------------------------------------
      def draw_line_segment(pt1, pt2)
        model = Sketchup.active_model
        entities = model.active_entities

        distance = pt1.distance(pt2)
        return if distance < 0.001

        new_dir = (pt2 - pt1)
        new_dir.normalize!

        # Check for 90° fillet with previous segment
        if @prev_line_dir && @prev_start_point
          angle = @prev_line_dir.angle_between(new_dir)
          is_90 = (angle - Math::PI / 2.0).abs < FILLET_ANGLE_TOL

          if is_90
            r = @fillet_radius
            prev_len = @prev_start_point.distance(pt1)

            if prev_len > r && distance > r
              model.start_operation('Draw Wiring Line+Fillet', true)
              begin
                # Remove previous line edges from collection and erase
                if @prev_line_edges && !@prev_line_edges.empty?
                  @prev_line_edges.each do |e|
                    @arc_edges_all.delete(e)
                    e.erase! if e.valid?
                  end
                end

                # Fillet geometry
                fillet_start = Geom::Point3d.new(
                  pt1.x - @prev_line_dir.x * r,
                  pt1.y - @prev_line_dir.y * r,
                  pt1.z - @prev_line_dir.z * r
                )
                fillet_end = Geom::Point3d.new(
                  pt1.x + new_dir.x * r,
                  pt1.y + new_dir.y * r,
                  pt1.z + new_dir.z * r
                )
                fillet_center = Geom::Point3d.new(
                  fillet_start.x + new_dir.x * r,
                  fillet_start.y + new_dir.y * r,
                  fillet_start.z + new_dir.z * r
                )

                # Redraw shortened previous line
                prev_edges = entities.add_edges(@prev_start_point, fillet_start)
                if prev_edges && !prev_edges.empty?
                  prev_edges.each do |edge|
                    edge.set_attribute(DICT_WIRE, 'wire_label', @wire_label)
                    edge.set_attribute(DICT_WIRE, 'wire_nb', @nb_wires)
                    edge.set_attribute(DICT_WIRE, 'wire_section', @wire_section)
                  end
                  @arc_edges_all.concat(prev_edges)
                end

                # Draw fillet arc (90°)
                start_vec = fillet_start - fillet_center
                end_vec = fillet_end - fillet_center
                cross = start_vec.cross(end_vec)
                normal = (cross.length > 0.001) ? cross : Z_AXIS

                arc_edges = entities.add_arc(
                  fillet_center, start_vec, normal, r,
                  0, Math::PI / 2.0, ARC_SEGMENTS
                )
                if arc_edges && !arc_edges.empty?
                  arc_edges.each do |edge|
                    edge.set_attribute(DICT_WIRE, 'wire_label', @wire_label)
                    edge.set_attribute(DICT_WIRE, 'wire_nb', @nb_wires)
                    edge.set_attribute(DICT_WIRE, 'wire_section', @wire_section)
                  end
                  @arc_edges_all.concat(arc_edges)
                end

                # Draw new line from fillet_end to pt2
                new_edges = entities.add_edges(fillet_end, pt2)
                if new_edges && !new_edges.empty?
                  new_edges.each do |edge|
                    edge.set_attribute(DICT_WIRE, 'wire_label', @wire_label)
                    edge.set_attribute(DICT_WIRE, 'wire_nb', @nb_wires)
                    edge.set_attribute(DICT_WIRE, 'wire_section', @wire_section)
                  end
                  @arc_edges_all.concat(new_edges)
                end

                @prev_line_edges = new_edges || []
                @prev_start_point = fillet_end
                @prev_line_dir = new_dir

                model.commit_operation
                return
              rescue => e
                model.abort_operation
                if @dialog
                  @dialog.execute_script("onDevicePlaceError('Line+Fillet error: #{e.message.gsub("'", "\\\\'")}')")
                end
                return
              end
            end
          end
        end

        # No fillet needed or first segment — draw straight line
        model.start_operation('Draw Wiring Line', true)
        begin
          edges = entities.add_edges(pt1, pt2)
          if edges && !edges.empty?
            edges.each do |edge|
              edge.set_attribute(DICT_WIRE, 'wire_label', @wire_label)
              edge.set_attribute(DICT_WIRE, 'wire_nb', @nb_wires)
              edge.set_attribute(DICT_WIRE, 'wire_section', @wire_section)
            end
            @arc_edges_all.concat(edges)
          end

          @prev_line_edges = edges || []
          @prev_start_point = pt1
          @prev_line_dir = new_dir

          model.commit_operation
        rescue => e
          model.abort_operation
          if @dialog
            @dialog.execute_script("onDevicePlaceError('Line error: #{e.message.gsub("'", "\\\\'")}')")
          end
        end
      end

      # -------------------------------------------------------
      # Draw a 2-point arc in the model (actual geometry)
      # Arc plane is always perpendicular to Z axis (horizontal)
      # Bulge (sagitta) = 1/4 of distance between pt1 and pt2
      # -------------------------------------------------------
      def draw_arc(pt1, pt2)
        model = Sketchup.active_model
        entities = model.active_entities

        distance = pt1.distance(pt2)
        return if distance < 0.001  # too close

        # Bulge height = distance / denominator
        h = distance / @bulge_denominator
        half_chord = distance / 2.0

        # Radius from sagitta formula: r = (h² + (d/2)²) / (2h)
        radius = (h * h + half_chord * half_chord) / (2.0 * h)

        # Midpoint between pt1 and pt2
        mid = Geom::Point3d.linear_combination(0.5, pt1, 0.5, pt2)

        # Direction along chord (pt1 → pt2)
        chord_dir = pt2 - pt1
        chord_dir.normalize!

        # Perpendicular to chord in XY plane (bulge direction)
        bulge_dir = calculate_bulge_dir(pt1, pt2)

        # Center offset from midpoint along bulge direction
        offset = radius - h
        center = Geom::Point3d.new(
          mid.x + bulge_dir.x * offset,
          mid.y + bulge_dir.y * offset,
          mid.z + bulge_dir.z * offset
        )

        # Centre to pt1 and pt2 vectors
        v1 = pt1 - center
        v2 = pt2 - center
        
        # Determine correct normal for CCW drawing from pt1 to pt2
        cross_val = v1.cross(v2)
        normal = (cross_val.z >= 0) ? Z_AXIS : Z_AXIS.reverse
        
        # Vector from center to pt1 (xaxis for add_arc)
        start_vec = v1
        
        # Sweep angle: 2 * arcsin(half_chord / radius)
        # Ensure positive sweep
        sweep = 2.0 * Math.asin([half_chord / radius, 1.0].min).abs
        
        model.start_operation('Draw Wiring Arc', true)

        begin
          arc_edges = entities.add_arc(
            center,       # center point
            start_vec,    # xaxis (from center to start)
            normal,       # dynamic normal (Z or -Z)
            radius,       # radius
            0,            # start_angle
            sweep,        # end_angle (sweep)
            ARC_SEGMENTS  # number of segments
          )

          if arc_edges && !arc_edges.empty?
            # Set arc edge attributes
            arc_edges.each do |edge|
              edge.set_attribute(DICT_WIRE, 'wire_label', @wire_label)
              edge.set_attribute(DICT_WIRE, 'wire_nb', @nb_wires)
              edge.set_attribute(DICT_WIRE, 'wire_section', @wire_section)
            end
            @arc_edges_all.concat(arc_edges)
          end

          model.commit_operation
        rescue => e
          model.abort_operation
          if @dialog
            @dialog.execute_script("onDevicePlaceError('Arc error: #{e.message.gsub("'", "\\\\'")}')")
          end
        end
      end

      # -------------------------------------------------------
      # Group all drawn arcs and set name + tag
      # -------------------------------------------------------
      def finish_and_group
        return if @arc_edges_all.empty?

        model = Sketchup.active_model
        entities = model.active_entities

        model.start_operation('Group Wiring', true)
        begin
          # Create or find the tag (layer) with the wire label name
          tag_name = @wire_label
          layers = model.layers
          tag = layers[tag_name]
          unless tag
            tag = layers.add(tag_name)
          end

          # --- Set SkhReport attributes on the Layer/Tag ---
          tag.set_attribute('SkhReport', 'Listed', true)

          # Build PriceTags JSON — description uses the wire label
          price_tags = [
            {
              "recid"                 => 1,
              "subject"               => "04. งานระบบไฟฟ้าและสื่อสาร | 04.03. งานเดินสายไฟฟ้า | 0403",
              "description"           => @wire_label,
              "input_quantities"      => 1,
              "source_quantities"     => 1,
              "quantities"            => 1,
              "unit"                  => "m",
              "price_unit"            => 0.0,
              "total_price_material_" => "0.00",
              "labour_cost_unit"      => 0.0,
              "total_price_labour_"   => "0.00",
              "total"                 => "0.00",
              "factor"                => 1.0,
              "input_unit"            => "m",
              "wasted"                => 0.0,
              "type"                  => "length",
              "comments"              => {
                "subject" => "", "description" => "",
                "input_quantities" => "", "source_quantities" => "",
                "quantities" => "", "unit" => "",
                "price_unit" => "", "total_price_material_" => "",
                "labour_cost_unit" => "", "total_price_labour_" => "",
                "total" => "", "factor" => "",
                "input_unit" => "", "wasted" => ""
              },
              "w2ui"                  => { "style" => "color: #FF0000;" }
            }
          ]
          tag.set_attribute('SkhReport', 'PriceTags', JSON.generate(price_tags))

          # Assign a color to the Tag
          tag.color = @wire_color

          # Create or find a material with the wire color for edge painting
          mat_name = "Wire_#{@wire_label}"
          materials = model.materials
          mat = materials[mat_name]
          unless mat
            mat = materials.add(mat_name)
            mat.color = @wire_color
          end

          # Group all arc edges
          group = entities.add_group(@arc_edges_all)
          group.name = @wire_label
          group.layer = tag

          # Paint all edges inside the group with the wire material
          group.entities.each do |e|
            e.material = mat if e.is_a?(Sketchup::Edge)
          end

          # Set wire attributes on the group
          group.set_attribute(DICT_WIRE, 'wire_label', @wire_label)
          group.set_attribute(DICT_WIRE, 'wire_nb', @nb_wires)
          group.set_attribute(DICT_WIRE, 'wire_section', @wire_section)
          group.set_attribute(DICT_WIRE, 'arc_count', @arc_count)

          model.commit_operation

          # Force Edge style to "Color by Material" and disable overrides
          ro = model.rendering_options
          ro['EdgeColorMode'] = 0
          ro['DrawSilhouettes'] = false
          ro['DisplayColorByLayer'] = false
          model.styles.update_selected_style  # Save this setting to current style

          # Select the group
          model.selection.clear
          model.selection.add(group)

          # Notify dialog
          if @dialog
            escaped = @wire_label.gsub("'", "\\\\'")
            @dialog.execute_script("onWiringGrouped('#{escaped}', #{@arc_count})")
          end

        rescue => e
          model.abort_operation
          if @dialog
            @dialog.execute_script("onDevicePlaceError('Group error: #{e.message.gsub("'", "\\\\'")}')")
          end
        end

        @arc_edges_all = []
        @arc_count = 0
      end

      # -------------------------------------------------------
      # Generate a unique color for this wire type
      # -------------------------------------------------------
      def generate_wire_color
        # Use a hash of the label to get a consistent, vivid color
        hue = (@wire_label.bytes.sum * 137) % 360
        # HSL to RGB with S=80%, L=50% for vivid colors
        Sketchup::Color.new(*hsl_to_rgb(hue, 0.8, 0.5))
      end

      def hsl_to_rgb(h, s, l)
        c = (1.0 - (2.0 * l - 1.0).abs) * s
        x = c * (1.0 - ((h / 60.0) % 2 - 1.0).abs)
        m = l - c / 2.0
        r1, g1, b1 = case (h / 60).to_i % 6
          when 0 then [c, x, 0]
          when 1 then [x, c, 0]
          when 2 then [0, c, x]
          when 3 then [0, x, c]
          when 4 then [x, 0, c]
          when 5 then [c, 0, x]
          else [0, 0, 0]
        end
        [((r1 + m) * 255).round, ((g1 + m) * 255).round, ((b1 + m) * 255).round]
      end

      # -------------------------------------------------------
      # Draw line preview (GL overlay) with 90° fillet indicator
      # -------------------------------------------------------
      def draw_line_preview(view, pt1, pt2)
        distance = pt1.distance(pt2)
        return if distance < 0.001

        new_dir = (pt2 - pt1)
        new_dir.normalize!

        # Check for 90° fillet preview
        if @prev_line_dir && @prev_start_point
          angle = @prev_line_dir.angle_between(new_dir)
          is_90 = (angle - Math::PI / 2.0).abs < FILLET_ANGLE_TOL

          if is_90
            r = @fillet_radius
            prev_len = @prev_start_point.distance(pt1)

            if prev_len > r && distance > r
              fillet_start = Geom::Point3d.new(
                pt1.x - @prev_line_dir.x * r,
                pt1.y - @prev_line_dir.y * r,
                pt1.z - @prev_line_dir.z * r
              )
              fillet_end = Geom::Point3d.new(
                pt1.x + new_dir.x * r,
                pt1.y + new_dir.y * r,
                pt1.z + new_dir.z * r
              )
              fillet_center = Geom::Point3d.new(
                fillet_start.x + new_dir.x * r,
                fillet_start.y + new_dir.y * r,
                fillet_start.z + new_dir.z * r
              )

              start_vec = fillet_start - fillet_center
              cross = start_vec.cross(fillet_end - fillet_center)
              normal = (cross.length > 0.001) ? cross : Z_AXIS

              # Generate fillet arc preview points
              fillet_points = []
              segments = ARC_SEGMENTS
              (0..segments).each do |i|
                a = (Math::PI / 2.0) * i / segments.to_f
                rot = Geom::Transformation.rotation(fillet_center, normal, a)
                pt = (fillet_center + start_vec).transform(rot)
                fillet_points << pt
              end

              # Draw trimmed corner as dashed (portion to be replaced by fillet)
              view.line_stipple = '-'
              view.line_width = 1
              view.drawing_color = Sketchup::Color.new(255, 100, 100, 150)
              view.draw(GL_LINES, [fillet_start, pt1, pt1, fillet_end])

              # Draw fillet arc preview
              view.line_stipple = ''
              view.line_width = 2
              view.drawing_color = Sketchup::Color.new(255, 165, 0, 220)
              view.draw(GL_LINE_STRIP, fillet_points)

              # Draw new line from fillet_end to cursor
              view.line_stipple = ''
              view.line_width = 2
              view.drawing_color = Sketchup::Color.new(0, 200, 80, 220)
              view.draw(GL_LINES, [fillet_end, pt2])

              # Distance text
              mid = Geom::Point3d.linear_combination(0.5, pt1, 0.5, pt2)
              screen_mid = view.screen_coords(mid)
              fillet_mm = @fillet_radius.to_mm.round(1)
              view.draw_text([screen_mid.x + 10, screen_mid.y - 10, 0],
                sprintf("%.2f m [Line+R#{fillet_mm}mm]", distance.to_m))
              return
            end
          end
        end

        # No fillet — straight line preview
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(0, 200, 80, 220)
        view.draw(GL_LINES, [pt1, pt2])

        mid = Geom::Point3d.linear_combination(0.5, pt1, 0.5, pt2)
        screen_mid = view.screen_coords(mid)
        view.draw_text([screen_mid.x + 10, screen_mid.y - 10, 0],
          sprintf("%.2f m [Line]", distance.to_m))
      end

      # -------------------------------------------------------
      # Draw arc preview (GL overlay, not actual geometry)
      # -------------------------------------------------------
      def draw_arc_preview(view, pt1, pt2)
        distance = pt1.distance(pt2)
        return if distance < 0.001

        # Same geometry as draw_arc: bulge = distance/denominator, Z_AXIS normal
        h = distance / @bulge_denominator
        half_chord = distance / 2.0
        radius = (h * h + half_chord * half_chord) / (2.0 * h)

        mid = Geom::Point3d.linear_combination(0.5, pt1, 0.5, pt2)
        chord_dir = pt2 - pt1
        chord_dir.normalize!

        bulge_dir = calculate_bulge_dir(pt1, pt2)

        offset = radius - h
        center = Geom::Point3d.new(
          mid.x + bulge_dir.x * offset,
          mid.y + bulge_dir.y * offset,
          mid.z + bulge_dir.z * offset
        )

        # Centre to pt1 and pt2 vectors
        v1 = pt1 - center
        v2 = pt2 - center
        
        # Determine correct normal
        cross_val = v1.cross(v2)
        normal = (cross_val.z >= 0) ? Z_AXIS : Z_AXIS.reverse

        start_vec = v1
        sweep = 2.0 * Math.asin([half_chord / radius, 1.0].min).abs

        # Generate preview arc points
        points = []
        segments = ARC_SEGMENTS
        (0..segments).each do |i|
          angle = sweep * i / segments.to_f
          rot = Geom::Transformation.rotation(center, normal, angle)
          pt = (center + start_vec).transform(rot)
          points << pt
        end

        # Draw dotted chord line
        view.line_stipple = '-'
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(255, 165, 0, 150)
        view.draw(GL_LINES, [pt1, pt2])

        # Draw arc preview
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(0, 200, 80, 220)
        view.draw(GL_LINE_STRIP, points)

        # Draw distance text
        screen_mid = view.screen_coords(mid)
        view.draw_text([screen_mid.x + 10, screen_mid.y - 10, 0],
          sprintf("%.2f m", distance.to_m))
      end

      # -------------------------------------------------------
      # Draw a colored point marker
      # -------------------------------------------------------
      def draw_point_marker(view, point, color)
        view.line_width = 2
        view.drawing_color = color
        s = 8
        sp = view.screen_coords(point)
        view.draw2d(GL_LINES, [
          [sp.x - s, sp.y - s, 0], [sp.x + s, sp.y + s, 0],
          [sp.x - s, sp.y + s, 0], [sp.x + s, sp.y - s, 0]
        ])
      end

      def update_vcb_label
        if @line_mode
          Sketchup.vcb_label = "Fillet Radius:"
          Sketchup.vcb_value = @fillet_radius.to_l.to_s
        else
          Sketchup.vcb_label = "Length:"
          Sketchup.vcb_value = ""
        end
      end

      def update_status_text
        fillet_mm = @fillet_radius.to_mm.round(1)
        mode_text = @line_mode ? " [Mode: Line+R#{fillet_mm}mm]" : " [Mode: Arc]"
        dir_text = @reverse_arc ? " [Bulge -]" : " [Bulge +]"
        height_text = " [H=1/#{@bulge_denominator.to_i}]"
        arc_opts = @line_mode ? " | VCB=Fillet Radius" : " | Tab=Toggle Bulge#{dir_text} | Alt=Toggle Height#{height_text}"

        lock_text = case @axis_lock
          when :x then " | Lock: Red(X)"
          when :y then " | Lock: Green(Y)"
          when :z then " | Lock: Blue(Z)"
          else ""
        end

        if @state == :pick_start
          Sketchup.status_text = "สายไฟ: #{@wire_label}#{mode_text} | Click=เลือกจุดเริ่มต้น, Space=จบ(Group) | วาดแล้ว: #{@arc_count} เส้น | Ctrl=Toggle Line/Arc#{arc_opts}#{lock_text}"
        else
          Sketchup.status_text = "สายไฟ: #{@wire_label}#{mode_text} | Click=เลือกจุดปลาย, Esc=ยกเลิกจุด | วาดแล้ว: #{@arc_count} เส้น | Ctrl=Toggle Line/Arc#{arc_opts}#{lock_text} | Shift=Lock Inferred | Arrows=Lock Axis"
        end
      end

      # -------------------------------------------------------
      # Calculate Bulge Direction based on @reverse_arc
      # -------------------------------------------------------
      def calculate_bulge_dir(pt1, pt2)
        chord_dir = pt2 - pt1
        chord_dir.normalize!

        # Horizontal Plane (Default)
        # Reversed default to match user expectation (Left->Right = Up)
        bulge_dir = chord_dir.cross(Z_AXIS)
        
        if bulge_dir.length < 0.001
          # Chord is vertical
          bulge_dir = X_AXIS.clone
        else
          bulge_dir.normalize!
        end

        # Reverse if requested
        bulge_dir.reverse! if @reverse_arc

        bulge_dir
      end
    end

    # =========================================================
    # PlaceDeviceOnWallTool — Multi-step tool for precise
    # placement of devices on wall faces.
    #
    # Steps:
    #   1. Click Face  → determine wall plane & local axes
    #   2. Click Vertex → reference point on the wall
    #   3. Move mouse horizontally + type distance in VCB
    #   4. Move mouse vertically   + type distance in VCB → place
    #   5. Loop back to step 2 for continuous placement
    # =========================================================
    class PlaceDeviceOnWallTool

      DICT_DEVICE = 'SU_Electrical_Device'.freeze

      def initialize(comp_def, label, conn_type, skp_file, dialog = nil)
        @comp_def  = comp_def
        @label     = label
        @conn_type = conn_type
        @skp_file  = skp_file
        @dialog    = dialog
        @rot_x = 0
        @rot_y = 0
        @rot_z = 0
        @shift_held = false
        @placed_count = 0

        # Offset from Component Axis (persisted via Sketchup defaults, shared with PlaceDeviceTool)
        @offset_x = Sketchup.read_default('SKH_PlaceDevice', 'OffsetX', 0.0).to_f
        @offset_y = Sketchup.read_default('SKH_PlaceDevice', 'OffsetY', 0.0).to_f
        @offset_z = Sketchup.read_default('SKH_PlaceDevice', 'OffsetZ', 0.0).to_f
        @offset_mode = false  # true when waiting for VCB offset input

        # State machine
        @state = :pick_face

        # Face data
        @picked_face      = nil
        @face_normal      = nil
        @face_transform   = nil   # transformation of the group/component containing the face
        @face_vertices_world = []

        # Wall local axes (computed from face)
        @h_axis = nil   # horizontal direction on wall
        @v_axis = nil   # vertical direction on wall

        # Reference point
        @reference_point = nil

        # Horizontal step
        @h_direction = nil   # +1 or -1
        @h_distance  = 0.0
        @h_point     = nil   # intermediate point after horizontal offset

        # Vertical step
        @v_direction = nil
        @v_distance  = 0.0

        # Mouse tracking
        @input_point  = nil
        @current_pos  = ORIGIN
        @hover_face   = nil
        @hover_face_pts = []
      end

      # --- Tool lifecycle ---

      def activate
        @input_point = Sketchup::InputPoint.new
        update_status_text
        update_vcb
        notify_dialog_offset
        Sketchup.active_model.active_view.invalidate
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        update_status_text
        view.invalidate
      end

      def onSetCursor
        cursor_id = UI.create_cursor(
          File.join(EXTENSION_ROOT, 'images', 'input_devices_icon.png'), 0, 0
        ) rescue 0
        UI.set_cursor(cursor_id > 0 ? cursor_id : 0)
      end

      def enableVCB?; true; end

      # --- Mouse Move ---

      def onMouseMove(flags, x, y, view)
        @input_point.pick(view, x, y)
        @current_pos = @input_point.position

        case @state
        when :pick_face
          detect_face_under_cursor(view, x, y)
        when :pick_vertex
          # InputPoint handles vertex snapping automatically
        when :pick_horizontal
          update_horizontal_preview(view, x, y)
        when :pick_vertical
          update_vertical_preview(view, x, y)
        end

        view.tooltip = @input_point.tooltip if @input_point.valid?
        view.invalidate
      end

      # --- Mouse Click ---

      def onLButtonDown(flags, x, y, view)
        return unless @input_point.valid?

        case @state
        when :pick_face
          pick_face_action(view, x, y)
        when :pick_vertex
          pick_vertex_action(view)
        when :pick_horizontal
          pick_horizontal_action(view)
        when :pick_vertical
          pick_vertical_action(view)
        end

        view.invalidate
      end

      # --- VCB Input ---

      def onUserText(text, view)
        if @offset_mode
          # Parse offset X,Y,Z from VCB (formats: "X,Y,Z" or "X,Y" or single value)
          begin
            parts = text.strip.split(/[,;\s]+/)
            if parts.length >= 3
              @offset_x = parts[0].to_l.to_f
              @offset_y = parts[1].to_l.to_f
              @offset_z = parts[2].to_l.to_f
            elsif parts.length == 2
              @offset_x = parts[0].to_l.to_f
              @offset_y = parts[1].to_l.to_f
            elsif parts.length == 1
              val = parts[0].to_l.to_f
              @offset_x = val
              @offset_y = val
              @offset_z = 0.0
            else
              UI.beep
              Sketchup.status_text = "Invalid offset. Use: X,Y,Z (e.g. 100mm,50mm,0)"
              return
            end
            save_offsets
            @offset_mode = false
            update_status_text
            update_vcb
            notify_dialog_offset
            view.invalidate
          rescue ArgumentError
            UI.beep
            Sketchup.status_text = "Invalid offset value. Use: X,Y,Z (e.g. 100mm,50mm,0)"
          end
          return
        end

        begin
          dist = text.strip.to_l.to_f
        rescue ArgumentError
          UI.beep
          Sketchup.status_text = "Invalid distance value"
          return
        end

        case @state
        when :pick_horizontal
          @h_distance = dist.abs
          @h_direction ||= 1
          @h_point = compute_h_point
          @state = :pick_vertical
          @v_direction = nil
          @v_distance = 0.0
          update_status_text
          update_vcb
          view.invalidate

        when :pick_vertical
          @v_distance = dist.abs
          @v_direction ||= 1
          place_component_on_wall(view)
          view.invalidate
        end
      end

      # --- Keyboard ---

      def onKeyDown(key, repeat, flags, view)
        case key
        when 17 # Ctrl — toggle offset mode
          @offset_mode = !@offset_mode
          if @offset_mode
            Sketchup.status_text = "Offset Mode: พิมพ์ค่า X,Y,Z ใน VCB (เช่น 100mm,50mm,0) แล้วกด Enter | Esc=ยกเลิก"
            Sketchup.vcb_label = "Offset X,Y,Z:"
            Sketchup.vcb_value = "#{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}"
          else
            update_status_text
            update_vcb
          end
          view.invalidate
          return true
        when 27 # Escape
          if @offset_mode
            @offset_mode = false
            update_status_text
            update_vcb
            view.invalidate
            return true
          end
          go_back(view)
          return true
        when 16 # Shift
          @shift_held = true
          return true
        when 37 # Left Arrow
          if @shift_held  # Shift held → rotate around Y axis
            @rot_y = (@rot_y + 90) % 360
            update_status_text
            view.invalidate
          end
          return true
        when 39 # Right Arrow
          if @shift_held  # Shift held → rotate around X axis
            @rot_x = (@rot_x + 90) % 360
            update_status_text
            view.invalidate
          end
          return true
        when 38 # Up Arrow
          if @shift_held  # Shift held → rotate around Z axis
            @rot_z = (@rot_z + 90) % 360
            update_status_text
            view.invalidate
          end
          return true
        when 9 # Tab — flip direction
          flip_direction(view)
          return true
        end
        false
      end

      def onKeyUp(key, repeat, flags, view)
        if key == 16  # Shift released
          @shift_held = false
        end
        false
      end

      # --- Drawing ---

      def draw(view)
        case @state
        when :pick_face
          draw_face_highlight(view)
        when :pick_vertex
          draw_face_outline(view)
          draw_vertex_marker(view, @current_pos, Sketchup::Color.new(0, 200, 80, 255))
          draw_axes_indicator(view)
        when :pick_horizontal
          draw_face_outline(view)
          draw_ref_point(view)
          draw_horizontal_guide(view)
          draw_component_preview(view, compute_preview_pos_h)
        when :pick_vertical
          draw_face_outline(view)
          draw_ref_point(view)
          draw_fixed_h_line(view)
          draw_vertical_guide(view)
          draw_component_preview(view, compute_preview_pos_v)
        end

        # Draw offset indicator if offset is set
        draw_offset_indicator(view) if @offset_x != 0 || @offset_y != 0 || @offset_z != 0

        # Always draw input point inference
        @input_point.draw(view) if @input_point && @input_point.valid?
      end

      def getExtents
        bb = Geom::BoundingBox.new
        bb.add(@current_pos) if @current_pos
        bb.add(@reference_point) if @reference_point
        bb.add(@h_point) if @h_point
        @face_vertices_world.each { |pt| bb.add(pt) } unless @face_vertices_world.empty?
        bb
      end

      private

      # =======================================================
      # STATE ACTIONS
      # =======================================================

      def detect_face_under_cursor(view, x, y)
        ph = view.pick_helper
        ph.do_pick(x, y)

        best_face = nil
        best_path = nil

        # Search through pick results for a face
        ph.count.times do |i|
          path = ph.path_at(i)
          next unless path
          leaf = path.last
          if leaf.is_a?(Sketchup::Face)
            best_face = leaf
            best_path = path
            break
          end
        end

        if best_face
          @hover_face = best_face
          # Compute world-space transformation for this face
          xform = Geom::Transformation.new
          best_path[0...-1].each do |entity|
            if entity.respond_to?(:transformation)
              xform = xform * entity.transformation
            end
          end
          @hover_face_pts = best_face.outer_loop.vertices.map { |v| v.position.transform(xform) }
        else
          @hover_face = nil
          @hover_face_pts = []
        end
      end

      def pick_face_action(view, x, y)
        unless @hover_face
          UI.beep
          Sketchup.status_text = "No face detected — please click on a wall face"
          return
        end

        @picked_face = @hover_face

        # Compute the transformation for the face context
        ph = view.pick_helper
        ph.do_pick(x, y)
        xform = Geom::Transformation.new
        ph.count.times do |i|
          path = ph.path_at(i)
          next unless path
          if path.last == @picked_face
            path[0...-1].each do |entity|
              if entity.respond_to?(:transformation)
                xform = xform * entity.transformation
              end
            end
            break
          end
        end
        @face_transform = xform

        # Compute face normal in world space
        @face_normal = @picked_face.normal.transform(xform)
        @face_normal.normalize!

        # Store face vertices in world space
        @face_vertices_world = @picked_face.outer_loop.vertices.map { |v| v.position.transform(xform) }

        # Compute wall local axes
        compute_wall_axes

        @state = :pick_vertex
        update_status_text
        update_vcb
        view.invalidate
      end

      def compute_wall_axes
        # h_axis = horizontal direction on the wall face
        # For a typical vertical wall, this is cross(normal, Z)
        h = @face_normal.cross(Z_AXIS)
        if h.length < 0.001
          # Face is horizontal (floor/ceiling) — use X as horizontal
          h = X_AXIS.cross(@face_normal)
        end
        h.normalize!
        @h_axis = h

        # v_axis = vertical direction on the wall face
        v = @h_axis.cross(@face_normal)
        v.normalize!
        @v_axis = v
      end

      def pick_vertex_action(view)
        @reference_point = @input_point.position.clone
        @h_direction = nil
        @h_distance = 0.0
        @h_point = nil
        @v_direction = nil
        @v_distance = 0.0
        @state = :pick_horizontal
        update_status_text
        update_vcb
      end

      def pick_horizontal_action(view)
        return unless @reference_point && @h_axis
        # Use current mouse projection to determine direction and distance
        proj = project_on_axis(@current_pos, @reference_point, @h_axis)
        dist = @reference_point.distance(proj)
        dir = (@current_pos - @reference_point) % @h_axis
        @h_direction = dir >= 0 ? 1 : -1
        @h_distance = dist
        @h_point = compute_h_point
        @state = :pick_vertical
        @v_direction = nil
        @v_distance = 0.0
        update_status_text
        update_vcb
      end

      def pick_vertical_action(view)
        return unless @h_point && @v_axis
        proj = project_on_axis(@current_pos, @h_point, @v_axis)
        dist = @h_point.distance(proj)
        dir = (@current_pos - @h_point) % @v_axis
        @v_direction = dir >= 0 ? 1 : -1
        @v_distance = dist
        place_component_on_wall(view)
      end

      def update_horizontal_preview(view, x, y)
        return unless @reference_point && @h_axis
        proj = project_on_axis(@current_pos, @reference_point, @h_axis)
        dot = (@current_pos - @reference_point) % @h_axis
        @h_direction = dot >= 0 ? 1 : -1
        @h_distance = @reference_point.distance(proj)
      end

      def update_vertical_preview(view, x, y)
        return unless @h_point && @v_axis
        proj = project_on_axis(@current_pos, @h_point, @v_axis)
        dot = (@current_pos - @h_point) % @v_axis
        @v_direction = dot >= 0 ? 1 : -1
        @v_distance = @h_point.distance(proj)
      end

      # =======================================================
      # PLACEMENT
      # =======================================================

      def place_component_on_wall(view)
        final_pos = compute_final_position
        return unless final_pos

        model = Sketchup.active_model
        model.start_operation('Place Device on Wall', true)

        transform = build_wall_transform(final_pos)
        instance = model.active_entities.add_instance(@comp_def, transform)
        instance.set_attribute(DICT_DEVICE, 'device_label', @label)
        instance.set_attribute(DICT_DEVICE, 'device_type', @conn_type)
        instance.set_attribute(DICT_DEVICE, 'skp_file', @skp_file)

        model.commit_operation

        @placed_count += 1

        if @dialog
          escaped = @label.gsub("'", "\\\\'")
          @dialog.execute_script("onDevicePlacedOnWall('#{escaped}')")
        end

        # Loop back to pick_vertex for continuous placement on same wall
        @state = :pick_vertex
        @reference_point = nil
        @h_point = nil
        @h_distance = 0.0
        @v_distance = 0.0
        update_status_text
        update_vcb
        view.invalidate
      end

      def build_wall_transform(position)
        # Component orientation aligned to Model Axes (same as PlaceDeviceTool)
        offset = Geom::Transformation.new([@offset_x, @offset_y, @offset_z])
        move = Geom::Transformation.new(position)
        move * rotation_transform * offset
      end

      def rotation_transform
        rx = Geom::Transformation.rotation(ORIGIN, X_AXIS, @rot_x.degrees)
        ry = Geom::Transformation.rotation(ORIGIN, Y_AXIS, @rot_y.degrees)
        rz = Geom::Transformation.rotation(ORIGIN, Z_AXIS, @rot_z.degrees)
        rz * ry * rx
      end

      def compute_h_point
        return nil unless @reference_point && @h_axis && @h_direction
        dir = @h_direction >= 0 ? @h_axis : @h_axis.reverse
        @reference_point.offset(dir, @h_distance)
      end

      def compute_final_position
        return nil unless @h_point && @v_axis
        dir_v = (@v_direction && @v_direction >= 0) ? @v_axis : @v_axis.reverse
        @h_point.offset(dir_v, @v_distance)
      end

      def compute_preview_pos_h
        return @reference_point unless @reference_point && @h_axis
        dir = (@h_direction && @h_direction >= 0) ? @h_axis : @h_axis.reverse
        @reference_point.offset(dir, @h_distance)
      end

      def compute_preview_pos_v
        hp = compute_h_point
        return hp unless hp && @v_axis
        dir_v = (@v_direction && @v_direction >= 0) ? @v_axis : @v_axis.reverse
        hp.offset(dir_v, @v_distance)
      end

      # =======================================================
      # GEOMETRY HELPERS
      # =======================================================

      # Project a point onto an axis line passing through origin_pt
      def project_on_axis(point, origin_pt, axis)
        vec = point - origin_pt
        dot = vec % axis
        origin_pt.offset(axis, dot)
      end

      # =======================================================
      # NAVIGATION (Esc / Tab)
      # =======================================================

      def go_back(view)
        case @state
        when :pick_face
          Sketchup.active_model.select_tool(nil)
        when :pick_vertex
          @picked_face = nil
          @face_normal = nil
          @face_vertices_world = []
          @state = :pick_face
        when :pick_horizontal
          @reference_point = nil
          @state = :pick_vertex
        when :pick_vertical
          @h_point = nil
          @h_distance = 0.0
          @state = :pick_horizontal
        end
        update_status_text
        update_vcb
        view.invalidate
      end

      def flip_direction(view)
        case @state
        when :pick_horizontal
          @h_direction = @h_direction ? -@h_direction : 1
        when :pick_vertical
          @v_direction = @v_direction ? -@v_direction : 1
        end
        view.invalidate
      end

      # =======================================================
      # DRAWING HELPERS
      # =======================================================

      def draw_face_highlight(view)
        return if @hover_face_pts.empty?
        # Semi-transparent fill
        view.drawing_color = Sketchup::Color.new(0, 120, 215, 60)
        view.draw(GL_POLYGON, @hover_face_pts) if @hover_face_pts.length >= 3
        # Outline
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(0, 120, 215, 200)
        view.draw(GL_LINE_LOOP, @hover_face_pts)
      end

      def draw_face_outline(view)
        return if @face_vertices_world.empty?
        view.line_stipple = '-'
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(100, 100, 100, 120)
        view.draw(GL_LINE_LOOP, @face_vertices_world)
        view.line_stipple = ''
      end

      def draw_ref_point(view)
        return unless @reference_point
        draw_vertex_marker(view, @reference_point, Sketchup::Color.new(0, 200, 80, 255))
        # Label
        sp = view.screen_coords(@reference_point)
        view.draw_text([sp.x + 10, sp.y - 14, 0], "REF",
          size: 10, color: Sketchup::Color.new(0, 200, 80))
      end

      def draw_axes_indicator(view)
        return unless @face_vertices_world.length >= 2
        # Show H and V axes from center of face
        center = Geom::Point3d.new(
          @face_vertices_world.map(&:x).sum / @face_vertices_world.length,
          @face_vertices_world.map(&:y).sum / @face_vertices_world.length,
          @face_vertices_world.map(&:z).sum / @face_vertices_world.length
        )
        return unless @h_axis && @v_axis
        len = 500 # internal inches ≈ ~12m visual
        # H axis (red)
        view.line_stipple = '-'
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(220, 50, 50, 150)
        view.draw(GL_LINES, [center.offset(@h_axis, -len), center.offset(@h_axis, len)])
        # V axis (blue)
        view.drawing_color = Sketchup::Color.new(50, 50, 220, 150)
        view.draw(GL_LINES, [center.offset(@v_axis, -len), center.offset(@v_axis, len)])
        view.line_stipple = ''
        # Labels
        sp_h = view.screen_coords(center.offset(@h_axis, len * 0.3))
        view.draw_text([sp_h.x, sp_h.y - 12, 0], "H", size: 11, color: Sketchup::Color.new(220, 50, 50))
        sp_v = view.screen_coords(center.offset(@v_axis, len * 0.3))
        view.draw_text([sp_v.x + 6, sp_v.y, 0], "V", size: 11, color: Sketchup::Color.new(50, 50, 220))
      end

      def draw_horizontal_guide(view)
        return unless @reference_point && @h_axis
        dir = (@h_direction && @h_direction >= 0) ? @h_axis : @h_axis.reverse
        end_pt = @reference_point.offset(dir, @h_distance)

        # Guide line (red)
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(220, 50, 50, 220)
        view.draw(GL_LINES, [@reference_point, end_pt])

        # Extended dashed line
        view.line_stipple = '.'
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(220, 50, 50, 100)
        ext = @reference_point.offset(dir, [(@h_distance * 1.5), 200].max)
        view.draw(GL_LINES, [end_pt, ext])
        view.line_stipple = ''

        # Distance text
        mid = Geom::Point3d.linear_combination(0.5, @reference_point, 0.5, end_pt)
        sp = view.screen_coords(mid)
        view.draw_text([sp.x + 8, sp.y - 14, 0],
          "H: #{@h_distance.to_l}",
          size: 11, color: Sketchup::Color.new(220, 50, 50))

        # Endpoint marker
        draw_vertex_marker(view, end_pt, Sketchup::Color.new(220, 50, 50, 255))
      end

      def draw_fixed_h_line(view)
        return unless @reference_point && @h_point
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(220, 50, 50, 180)
        view.draw(GL_LINES, [@reference_point, @h_point])
        # H distance text
        mid = Geom::Point3d.linear_combination(0.5, @reference_point, 0.5, @h_point)
        sp = view.screen_coords(mid)
        view.draw_text([sp.x + 8, sp.y - 14, 0],
          "H: #{@h_distance.to_l}",
          size: 10, color: Sketchup::Color.new(220, 50, 50))
        draw_vertex_marker(view, @h_point, Sketchup::Color.new(220, 50, 50, 200))
      end

      def draw_vertical_guide(view)
        return unless @h_point && @v_axis
        dir = (@v_direction && @v_direction >= 0) ? @v_axis : @v_axis.reverse
        end_pt = @h_point.offset(dir, @v_distance)

        # Guide line (blue)
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(50, 50, 220, 220)
        view.draw(GL_LINES, [@h_point, end_pt])

        # Extended dashed line
        view.line_stipple = '.'
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(50, 50, 220, 100)
        ext = @h_point.offset(dir, [(@v_distance * 1.5), 200].max)
        view.draw(GL_LINES, [end_pt, ext])
        view.line_stipple = ''

        # Distance text
        mid = Geom::Point3d.linear_combination(0.5, @h_point, 0.5, end_pt)
        sp = view.screen_coords(mid)
        view.draw_text([sp.x + 8, sp.y - 14, 0],
          "V: #{@v_distance.to_l}",
          size: 11, color: Sketchup::Color.new(50, 50, 220))

        # Endpoint marker
        draw_vertex_marker(view, end_pt, Sketchup::Color.new(50, 50, 220, 255))
      end

      def draw_component_preview(view, position)
        return unless position && @comp_def
        transform = build_wall_transform(position)

        # Semi-transparent faces
        view.drawing_color = Sketchup::Color.new(0, 120, 215, 50)
        collect_entities_recursive(@comp_def.entities, transform) do |entity, xform|
          if entity.is_a?(Sketchup::Face)
            pts = entity.outer_loop.vertices.map { |v| v.position.transform(xform) }
            view.draw(GL_POLYGON, pts) if pts.length >= 3
          end
        end

        # Edges (wireframe)
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(0, 120, 215, 180)
        collect_entities_recursive(@comp_def.entities, transform) do |entity, xform|
          if entity.is_a?(Sketchup::Edge)
            pt1 = entity.start.position.transform(xform)
            pt2 = entity.end.position.transform(xform)
            view.draw(GL_LINES, [pt1, pt2])
          end
        end

        # Crosshair
        view.line_stipple = ''
        view.line_width = 1
        view.drawing_color = Sketchup::Color.new(255, 0, 0, 200)
        s = 20
        sp = view.screen_coords(position)
        view.draw2d(GL_LINES, [
          [sp.x - s, sp.y, 0], [sp.x + s, sp.y, 0],
          [sp.x, sp.y - s, 0], [sp.x, sp.y + s, 0]
        ])
      end

      def draw_vertex_marker(view, point, color)
        d = 6
        sp = view.screen_coords(point)
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = color
        view.draw2d(GL_LINE_LOOP, [
          [sp.x, sp.y - d, 0], [sp.x + d, sp.y, 0],
          [sp.x, sp.y + d, 0], [sp.x - d, sp.y, 0]
        ])
      end

      def draw_offset_indicator(view)
        # Show offset info near the current preview position
        pos = case @state
              when :pick_horizontal then compute_preview_pos_h
              when :pick_vertical then compute_preview_pos_v
              else @current_pos
              end
        return unless pos

        # Compute offset origin in world space (aligned to Model Axes)
        begin
          offset_local = Geom::Point3d.new(@offset_x, @offset_y, @offset_z)
          offset_world = offset_local.transform(
            rotation_transform
          ).transform(
            Geom::Transformation.new(pos)
          )
          sp0 = view.screen_coords(pos)
          sp  = view.screen_coords(offset_world)

          # Dashed line from placement point to offset component origin
          view.line_stipple = '.'
          view.line_width = 1
          view.drawing_color = Sketchup::Color.new(255, 140, 0, 200)
          view.draw2d(GL_LINES, [[sp0.x, sp0.y, 0], [sp.x, sp.y, 0]])

          # Diamond marker at offset origin
          d = 5
          view.line_stipple = ''
          view.line_width = 2
          view.drawing_color = Sketchup::Color.new(255, 140, 0, 255)
          view.draw2d(GL_LINE_LOOP, [
            [sp.x, sp.y - d, 0], [sp.x + d, sp.y, 0],
            [sp.x, sp.y + d, 0], [sp.x - d, sp.y, 0]
          ])

          # Offset text
          view.draw_text([sp.x + 8, sp.y - 12, 0],
            "Offset: #{@offset_x.to_l}, #{@offset_y.to_l}, #{@offset_z.to_l}",
            size: 10, color: Sketchup::Color.new(255, 140, 0))
        end
      end

      # Recursively iterate entities, descending into groups/components
      def collect_entities_recursive(entities, parent_transform, &block)
        entities.each do |entity|
          case entity
          when Sketchup::Group
            combined = parent_transform * entity.transformation
            collect_entities_recursive(entity.entities, combined, &block)
          when Sketchup::ComponentInstance
            combined = parent_transform * entity.transformation
            collect_entities_recursive(entity.definition.entities, combined, &block)
          else
            block.call(entity, parent_transform)
          end
        end
      end

      # =======================================================
      # STATUS / VCB
      # =======================================================

      def update_status_text
        has_offset = (@offset_x != 0 || @offset_y != 0 || @offset_z != 0)
        offset_info = has_offset ? " | Offset: #{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}" : ""
        rot_info = rotation_info_str
        case @state
        when :pick_face
          Sketchup.status_text = "วางบนผนัง: #{@label}#{offset_info}#{rot_info} | Click Face ของผนัง | Ctrl=Offset | Shift+←=หมุนY Shift+→=หมุนX Shift+↑=หมุนZ | Esc=ยกเลิก"
        when :pick_vertex
          Sketchup.status_text = "วางบนผนัง: #{@label}#{offset_info}#{rot_info} | Click จุดอ้างอิง | Ctrl=Offset | Shift+←→↑=หมุน | Esc=กลับ"
        when :pick_horizontal
          Sketchup.status_text = "วางบนผนัง: #{@label}#{offset_info}#{rot_info} | แนวนอน+VCB | Tab=สลับทิศ | Ctrl=Offset | Shift+←→↑=หมุน | Esc=กลับ"
        when :pick_vertical
          Sketchup.status_text = "วางบนผนัง: #{@label}#{offset_info}#{rot_info} | แนวตั้ง+VCB | Tab=สลับทิศ | Ctrl=Offset | Shift+←→↑=หมุน | Esc=กลับ"
        end
      end

      def rotation_info_str
        parts = []
        parts << "X:#{@rot_x}°" if @rot_x != 0
        parts << "Y:#{@rot_y}°" if @rot_y != 0
        parts << "Z:#{@rot_z}°" if @rot_z != 0
        parts.empty? ? "" : " | หมุน: #{parts.join(' ')}"
      end

      def update_vcb
        if @offset_mode
          Sketchup.vcb_label = "Offset X,Y,Z:"
          Sketchup.vcb_value = "#{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}"
          return
        end
        case @state
        when :pick_face, :pick_vertex
          if @offset_x != 0 || @offset_y != 0 || @offset_z != 0
            Sketchup.vcb_label = "Offset:"
            Sketchup.vcb_value = "#{@offset_x.to_l},#{@offset_y.to_l},#{@offset_z.to_l}"
          else
            Sketchup.vcb_label = ""
            Sketchup.vcb_value = ""
          end
        when :pick_horizontal
          Sketchup.vcb_label = "ระยะแนวนอน:"
          Sketchup.vcb_value = @h_distance.to_l.to_s
        when :pick_vertical
          Sketchup.vcb_label = "ระยะแนวตั้ง:"
          Sketchup.vcb_value = @v_distance.to_l.to_s
        end
      end

      def save_offsets
        Sketchup.write_default('SKH_PlaceDevice', 'OffsetX', @offset_x)
        Sketchup.write_default('SKH_PlaceDevice', 'OffsetY', @offset_y)
        Sketchup.write_default('SKH_PlaceDevice', 'OffsetZ', @offset_z)
      end

      def notify_dialog_offset
        return unless @dialog
        @dialog.execute_script(
          "if(typeof onOffsetChanged==='function') onOffsetChanged('#{@offset_x.to_l}', '#{@offset_y.to_l}', '#{@offset_z.to_l}');"
        )
      end

    end

    # =========================================================
    # UILogic — Dialog and callbacks
    # =========================================================
    module UILogic

      DICT_DEVICE = 'SU_Electrical_Device'.freeze
      DICT_WIRE   = 'SU_Electrical_Wire'.freeze

      # Return keyboard focus from HtmlDialog to SketchUp viewport (Windows)
      def self.focus_sketchup_viewport
        return unless Sketchup.platform == :platform_win
        require 'fiddle'
        user32 = Fiddle.dlopen('user32')
        get_fg  = Fiddle::Function.new(user32['GetForegroundWindow'], [], Fiddle::TYPE_UINTPTR_T)
        get_win = Fiddle::Function.new(user32['GetWindow'], [Fiddle::TYPE_UINTPTR_T, Fiddle::TYPE_INT], Fiddle::TYPE_UINTPTR_T)
        set_fg  = Fiddle::Function.new(user32['SetForegroundWindow'], [Fiddle::TYPE_UINTPTR_T], Fiddle::TYPE_INT)
        dialog_hwnd = get_fg.call
        owner_hwnd  = get_win.call(dialog_hwnd, 4) # GW_OWNER = 4
        set_fg.call(owner_hwnd) if owner_hwnd && owner_hwnd != 0
      rescue => e
        # Silent fallback — user can click viewport to regain focus
      end

      @input_devices_dialog = nil

      def self.toggle_input_devices_dialog
        if @input_devices_dialog
          @input_devices_dialog.close
          return
        end

        dialog = UI::HtmlDialog.new({
          dialog_title: "Input Devices & Wirings",
          preferences_key: "SKH_InputDevices",
          scrollable: true,
          resizable: true,
          width: 300,
          height: 420,
          style: UI::HtmlDialog::STYLE_DIALOG
        })

        html_path = File.join(EXTENSION_ROOT, 'html', 'input_devices.html')
        dialog.set_file(html_path)

        # Shared reference to currently active placement tool (captured by closures)
        active_place_tool = nil

        # Runtime list of custom devices added by user (appended beyond DEVICES_TAB)
        custom_devices = []

        # Runtime list of custom wires added by user (appended beyond WIRE_TYPES_TAB)
        custom_wires = []

        # --- Callback: Send devices data to HTML ---
        dialog.add_action_callback("getDevicesData") do |_ctx|
          json = JSON.generate(InputDevicesData::DEVICES_TAB)
          dialog.execute_script("onDevicesDataReceived('#{json.gsub("'", "\\\\'")}')")
        end

        # --- Callback: Send wires data to HTML ---
        dialog.add_action_callback("getWiresData") do |_ctx|
          json = JSON.generate(InputDevicesData::WIRE_TYPES_TAB)
          dialog.execute_script("onWiresDataReceived('#{json.gsub("'", "\\\\'")}')")
        end

        # --- Callback: Send connection types to HTML ---
        dialog.add_action_callback("getConnectionTypes") do |_ctx|
          json = JSON.generate(InputDevicesData::CONNECTION_TYPES)
          dialog.execute_script("onConnectionTypesReceived('#{json.gsub("'", "\\\\'")}')")
        end

        # --- Callback: Get device thumbnail preview (ISO / TOP) ---
        dialog.add_action_callback("getDevicePreview") do |_ctx, device_index, view_type|
          begin
            idx = device_index.to_i
            vtype = (view_type || 'iso').to_s.strip.downcase
            vtype = 'iso' unless %w[iso top].include?(vtype)

            static_count = InputDevicesData::DEVICES_TAB.length
            device = if idx < static_count
                       InputDevicesData::DEVICES_TAB[idx]
                     else
                       custom_devices[idx - static_count]
                     end
            unless device
              dialog.execute_script("onPreviewError('Device not found')")
              next
            end

            skp_file = device[1]
            comp_path = File.join(InputDevicesData::COMPONENTS_DIR, skp_file)

            unless File.exist?(comp_path)
              dialog.execute_script("onPreviewError('File not found')")
              next
            end

            model = Sketchup.active_model
            comp_def = model.definitions.load(comp_path)

            unless comp_def
              dialog.execute_script("onPreviewError('Cannot load component')")
              next
            end

            temp_path = File.join(Sketchup.temp_dir, "skh_device_preview.png")
            view = model.active_view

            # Save current camera state (camera is NOT part of undo stack)
            cam = view.camera
            saved_eye    = cam.eye.clone
            saved_target = cam.target.clone
            saved_up     = cam.up.clone
            saved_persp  = cam.perspective?
            saved_fov    = cam.fov

            # Use an operation so we can abort to cleanly revert entity changes
            model.start_operation('SKH Preview', true)

            # Hide all top-level entities
            model.entities.each { |e| e.visible = false rescue nil }

            # Place component at origin
            inst = model.entities.add_instance(comp_def, ORIGIN)

            # Calculate camera from component bounds
            bb = comp_def.bounds
            center = bb.center
            diag = bb.diagonal
            diag = 10.0 if diag < 1.0
            dist = diag * 2.0

            if vtype == 'top'
              eye    = Geom::Point3d.new(center.x, center.y, center.z + dist)
              target = Geom::Point3d.new(center.x, center.y, center.z)
              up     = Geom::Vector3d.new(0, 1, 0)
            else # iso
              d = dist / Math.sqrt(3.0)
              eye    = Geom::Point3d.new(center.x + d, center.y - d, center.z + d)
              target = Geom::Point3d.new(center.x, center.y, center.z)
              up     = Geom::Vector3d.new(0, 0, 1)
            end

            view.camera = Sketchup::Camera.new(eye, target, up, false)
            view.zoom_extents

            # Render to file
            view.write_image(temp_path, 400, 400, true)

            # Abort operation to undo all entity changes (hide/show + temp instance)
            model.abort_operation

            # Restore camera
            restored_cam = Sketchup::Camera.new(saved_eye, saved_target, saved_up, saved_persp)
            restored_cam.fov = saved_fov if saved_persp
            view.camera = restored_cam

            if File.exist?(temp_path)
              require 'base64'
              data = File.binread(temp_path)
              b64 = Base64.strict_encode64(data)
              dialog.execute_script("onPreviewReceived('data:image/png;base64,#{b64}')")
              File.delete(temp_path) rescue nil
            else
              dialog.execute_script("onPreviewError('Render failed')")
            end

          rescue => e
            model.abort_operation rescue nil
            dialog.execute_script("onPreviewError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        # --- Callback: Update component — save selected component back to components folder ---
        dialog.add_action_callback("updateComponent") do |_ctx, device_index|
          begin
            idx = device_index.to_i
            static_count = InputDevicesData::DEVICES_TAB.length
            device = if idx < static_count
                       InputDevicesData::DEVICES_TAB[idx]
                     else
                       custom_devices[idx - static_count]
                     end
            unless device
              dialog.execute_script("onComponentUpdateError('Device not found')")
              next
            end

            skp_file = device[1]
            comp_path = File.join(InputDevicesData::COMPONENTS_DIR, skp_file)

            # Find the component definition in the model by matching the loaded file name
            model = Sketchup.active_model
            comp_def = model.definitions.find { |d| d.path == comp_path || d.name == File.basename(skp_file, '.skp') }

            unless comp_def
              # Try loading it first
              if File.exist?(comp_path)
                comp_def = model.definitions.load(comp_path)
              end
            end

            unless comp_def
              dialog.execute_script("onComponentUpdateError('Component definition not found in model')")
              next
            end

            # Save the component definition back to the components folder
            success = comp_def.save_as(comp_path)

            if success
              dialog.execute_script("onComponentUpdated('#{skp_file.gsub("'", "\\\\'")}')")
            else
              dialog.execute_script("onComponentUpdateError('Failed to save file')")
            end

          rescue => e
            dialog.execute_script("onComponentUpdateError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        # --- Callback: Save last selected device/wire index ---
        dialog.add_action_callback("saveLastSelection") do |_ctx, device_idx, wire_idx|
          Sketchup.write_default('SKH_PlaceDevice', 'LastDeviceIndex', device_idx.to_i)
          Sketchup.write_default('SKH_PlaceDevice', 'LastWireIndex', wire_idx.to_i)
        end

        # --- Callback: Get last selected device/wire index ---
        dialog.add_action_callback("getLastSelection") do |_ctx|
          d_idx = Sketchup.read_default('SKH_PlaceDevice', 'LastDeviceIndex', -1).to_i
          w_idx = Sketchup.read_default('SKH_PlaceDevice', 'LastWireIndex', -1).to_i
          dialog.execute_script("onLastSelectionReceived(#{d_idx}, #{w_idx})")
        end

        # --- Callback: Get saved offset values ---
        dialog.add_action_callback("getOffset") do |_ctx|
          ox = Sketchup.read_default('SKH_PlaceDevice', 'OffsetX', 0.0).to_f
          oy = Sketchup.read_default('SKH_PlaceDevice', 'OffsetY', 0.0).to_f
          oz = Sketchup.read_default('SKH_PlaceDevice', 'OffsetZ', 0.0).to_f
          dialog.execute_script("onOffsetReceived('#{ox.to_l}', '#{oy.to_l}', '#{oz.to_l}')")
        end

        # --- Callback: Set offset values from HTML (values are unit strings) ---
        dialog.add_action_callback("setOffset") do |_ctx, ox, oy, oz|
          begin
            fx = ox.to_s.to_l.to_f
            fy = oy.to_s.to_l.to_f
            fz = oz.to_s.to_l.to_f
          rescue ArgumentError
            fx = ox.to_f
            fy = oy.to_f
            fz = oz.to_f
          end
          Sketchup.write_default('SKH_PlaceDevice', 'OffsetX', fx)
          Sketchup.write_default('SKH_PlaceDevice', 'OffsetY', fy)
          Sketchup.write_default('SKH_PlaceDevice', 'OffsetZ', fz)
          # Update active tool's offset in real-time for live preview
          if active_place_tool
            active_place_tool.instance_variable_set(:@offset_x, fx)
            active_place_tool.instance_variable_set(:@offset_y, fy)
            active_place_tool.instance_variable_set(:@offset_z, fz)
            Sketchup.active_model.active_view.invalidate
          end
          # Send formatted values back so HTML shows correct model units
          dialog.execute_script("onOffsetReceived('#{fx.to_l}', '#{fy.to_l}', '#{fz.to_l}')")
        end

        # --- Callback: Live offset update from HTML (no echo back to avoid overwriting user input) ---
        dialog.add_action_callback("setOffsetLive") do |_ctx, ox, oy, oz|
          begin
            fx = ox.to_s.to_l.to_f
            fy = oy.to_s.to_l.to_f
            fz = oz.to_s.to_l.to_f
          rescue ArgumentError
            # Gracefully handle incomplete input like "-" or "0." while user is still typing
            fx = ox.to_f rescue 0.0
            fy = oy.to_f rescue 0.0
            fz = oz.to_f rescue 0.0
          end
          Sketchup.write_default('SKH_PlaceDevice', 'OffsetX', fx)
          Sketchup.write_default('SKH_PlaceDevice', 'OffsetY', fy)
          Sketchup.write_default('SKH_PlaceDevice', 'OffsetZ', fz)
          # Update active tool for live preview — NO echo back to HTML
          if active_place_tool
            active_place_tool.instance_variable_set(:@offset_x, fx)
            active_place_tool.instance_variable_set(:@offset_y, fy)
            active_place_tool.instance_variable_set(:@offset_z, fz)
            Sketchup.active_model.active_view.invalidate
          end
        end

        # --- Callback: Set Tag View Mode (All / 3D / 2D) ---
        dialog.add_action_callback("setTagViewMode") do |_ctx, mode|
          begin
            model = Sketchup.active_model
            layers = model.layers
            tag_2d = layers['EE_2D']
            tag_device = layers['EE_Device']

            case mode.to_s.downcase
            when 'all'
              tag_2d.visible = true if tag_2d
              tag_device.visible = true if tag_device
            when '3d'
              tag_2d.visible = false if tag_2d
              tag_device.visible = true if tag_device
            when '2d'
              tag_2d.visible = true if tag_2d
              tag_device.visible = false if tag_device

              # Load style for color by material (same as Draw Wiring-Arc)
              style_path = File.join(EXTENSION_ROOT, 'style', 'Color by Material.style')
              if File.exist?(style_path)
                model.styles.add_style(style_path, true)
              end
              ro = model.rendering_options
              ro['EdgeColorMode'] = 0
              ro['DrawSilhouettes'] = false
              ro['DisplayColorByLayer'] = false
              model.styles.update_selected_style
            end

            model.active_view.invalidate
          rescue => e
            puts "setTagViewMode error: #{e.message}"
          end
        end

        # --- Callback: Resize Dialog (Auto-Fit height only, width fixed) ---
        dialog.add_action_callback("resizeDialog") do |_ctx, height|
          begin
            h = height.to_i
            final_h = [h + 45, 100].max

            dialog.set_size(300, final_h)
          rescue => e
            puts "resizeDialog error: #{e.message}"
          end
        end

        # --- Callback: Place device — activates PlaceDeviceTool ---
        dialog.add_action_callback("placeDevice") do |_ctx, device_index|
          begin
            idx = device_index.to_i
            static_count = InputDevicesData::DEVICES_TAB.length
            device = if idx < static_count
                       InputDevicesData::DEVICES_TAB[idx]
                     else
                       custom_devices[idx - static_count]
                     end
            unless device
              dialog.execute_script("onDevicePlaceError('Device not found')")
              next
            end
            
            # Blur HTML focus + return OS keyboard focus to SketchUp viewport
            dialog.execute_script("if(document.activeElement) document.activeElement.blur();")


            label = device[0]
            skp_file = device[1]
            conn_type = device[2]
            comp_path = File.join(InputDevicesData::COMPONENTS_DIR, skp_file)

            unless File.exist?(comp_path)
              dialog.execute_script("onDevicePlaceError('Component file not found: #{skp_file}')")
              next
            end

            model = Sketchup.active_model
            comp_def = model.definitions.load(comp_path)

            unless comp_def
              dialog.execute_script("onDevicePlaceError('Failed to load component: #{skp_file}')")
              next
            end

            # Clear Z-Plane so each new placement starts without Alt z-plane lock
            Sketchup.write_default('SKH_PlaceDevice', 'ZPlaneHeight', '')

            tool = PlaceDeviceTool.new(comp_def, label, conn_type, skp_file, dialog)
            active_place_tool = tool
            model.select_tool(tool)
            UI.start_timer(0.05, false) { focus_sketchup_viewport }

          rescue => e
            dialog.execute_script("onDevicePlaceError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        # --- Callback: Place device on wall — activates PlaceDeviceOnWallTool ---
        dialog.add_action_callback("placeDeviceOnWall") do |_ctx, device_index|
          begin
            idx = device_index.to_i
            static_count = InputDevicesData::DEVICES_TAB.length
            device = if idx < static_count
                       InputDevicesData::DEVICES_TAB[idx]
                     else
                       custom_devices[idx - static_count]
                     end
            unless device
              dialog.execute_script("onDevicePlaceError('Device not found')")
              next
            end

            # Blur HTML focus + return OS keyboard focus to SketchUp viewport
            dialog.execute_script("if(document.activeElement) document.activeElement.blur();")

            label = device[0]
            skp_file = device[1]
            conn_type = device[2]
            comp_path = File.join(InputDevicesData::COMPONENTS_DIR, skp_file)

            unless File.exist?(comp_path)
              dialog.execute_script("onDevicePlaceError('Component file not found: #{skp_file}')")
              next
            end

            model = Sketchup.active_model
            comp_def = model.definitions.load(comp_path)

            unless comp_def
              dialog.execute_script("onDevicePlaceError('Failed to load component: #{skp_file}')")
              next
            end

            tool = PlaceDeviceOnWallTool.new(comp_def, label, conn_type, skp_file, dialog)
            active_place_tool = tool
            model.select_tool(tool)
            UI.start_timer(0.05, false) { focus_sketchup_viewport }

          rescue => e
            dialog.execute_script("onDevicePlaceError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        # --- Callback: Select wire — activates DrawWiringTool ---
        dialog.add_action_callback("selectWire") do |_ctx, wire_index|
          begin
            idx = wire_index.to_i
            static_count = InputDevicesData::WIRE_TYPES_TAB.length
            wire = if idx < static_count
                     InputDevicesData::WIRE_TYPES_TAB[idx]
                   else
                     custom_wires[idx - static_count]
                   end
            unless wire
              dialog.execute_script("onDevicePlaceError('Wire type not found')")
              next
            end

            # Blur HTML focus + return OS keyboard focus to SketchUp viewport
            dialog.execute_script("if(document.activeElement) document.activeElement.blur();")


            label = wire[0]
            nb_wires = wire[1]
            section = wire[2]

            # Activate the interactive wiring drawing tool
            model = Sketchup.active_model
            tool = DrawWiringTool.new(label, nb_wires, section, dialog)
            model.select_tool(tool)
            UI.start_timer(0.05, false) { focus_sketchup_viewport }

            escaped_label = label.gsub("'", "\\\\'")
            dialog.execute_script("onWireSelected('#{escaped_label}')")

          rescue => e
            dialog.execute_script("onDevicePlaceError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        # --- Callback: Apply Custom Wiring ---
        dialog.add_action_callback("applyCustomWiring") do |_ctx, wire_name, nb_cores, wire_section|
          begin
            wire_name    = wire_name.to_s.strip
            nb_cores     = nb_cores.to_s.strip
            wire_section = wire_section.to_s.strip

            if wire_name.empty?
              dialog.execute_script("onCustomWiringError('กรุณาพิมพ์ชื่อสายไฟ/ท่อร้อยสาย')")
              next
            end

            nb_cores     = '2'   if nb_cores.empty?
            wire_section = '1.5' if wire_section.empty?

            new_wire = [wire_name, nb_cores, wire_section]
            custom_wires << new_wire
            json = JSON.generate(new_wire)
            dialog.execute_script("onCustomWiringApplied('#{json.gsub("'", "\\\\'")}')")

          rescue => e
            dialog.execute_script("onCustomWiringError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        # --- Callback: Apply Custom Device from selection ---
        dialog.add_action_callback("applyCustomDevice") do |_ctx, device_name|
          begin
            device_name = device_name.to_s.strip
            conn_type   = 'custom'

            if device_name.empty?
              dialog.execute_script("onCustomDeviceError('กรุณาพิมพ์ชื่ออุปกรณ์')")
              next
            end

            model = Sketchup.active_model
            sel   = model.selection

            # Validate: exactly 1 Group or ComponentInstance selected
            if sel.count != 1
              dialog.execute_script("onCustomDeviceError('กรุณา Select ชิ้นงาน Group หรือ Component 1 ชิ้นใน Model ก่อน')")
              next
            end

            entity = sel.first
            unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
              dialog.execute_script("onCustomDeviceError('ชิ้นงานที่เลือกต้องเป็น Group หรือ Component เท่านั้น')")
              next
            end

            # Sanitize file name
            safe_name = device_name.gsub(/[^a-zA-Z0-9\s_\-\u0E00-\u0E7F]/, '').strip
            safe_name = "CustomDevice" if safe_name.empty?
            skp_filename = "#{safe_name}.skp"
            comp_path = File.join(InputDevicesData::COMPONENTS_DIR, skp_filename)

            model.start_operation('Create Custom Device', true)

            comp_def = nil
            if entity.is_a?(Sketchup::Group)
              # Convert Group to Component
              comp_inst = entity.to_component
              comp_def  = comp_inst.definition
              comp_def.name = device_name
            else
              # Already a ComponentInstance — rename its definition
              comp_def = entity.definition
              comp_def.name = device_name
              comp_inst = entity
            end

            model.commit_operation

            # Save the component definition as .skp file
            comp_def.save_as(comp_path)

            # --- Generate thumbnail preview ---
            temp_path = File.join(Sketchup.temp_dir, "skh_custom_device_preview.png")
            view = model.active_view

            # Save current camera
            cam = view.camera
            saved_eye    = cam.eye.clone
            saved_target = cam.target.clone
            saved_up     = cam.up.clone
            saved_persp  = cam.perspective?
            saved_fov    = cam.fov

            model.start_operation('SKH Custom Preview', true)

            # Hide all entities
            model.entities.each { |e| e.visible = false rescue nil }

            # Place temp instance at origin
            temp_inst = model.entities.add_instance(comp_def, ORIGIN)

            # Set camera for ISO view
            bb = comp_def.bounds
            center = bb.center
            diag = bb.diagonal
            diag = 10.0 if diag < 1.0
            dist = diag * 2.0
            d = dist / Math.sqrt(3.0)
            eye    = Geom::Point3d.new(center.x + d, center.y - d, center.z + d)
            target = center
            up     = Geom::Vector3d.new(0, 0, 1)

            view.camera = Sketchup::Camera.new(eye, target, up, false)
            view.zoom_extents

            view.write_image(temp_path, 400, 400, true)

            model.abort_operation

            # Restore camera
            restored_cam = Sketchup::Camera.new(saved_eye, saved_target, saved_up, saved_persp)
            restored_cam.fov = saved_fov if saved_persp
            view.camera = restored_cam

            # Send preview to HTML
            if File.exist?(temp_path)
              require 'base64'
              data = File.binread(temp_path)
              b64 = Base64.strict_encode64(data)
              dialog.execute_script("onCustomDevicePreview('data:image/png;base64,#{b64}')")
              File.delete(temp_path) rescue nil
            end

            # Build device entry: [label, skp_file, connection_type]
            new_device = [device_name, skp_filename, conn_type]
            custom_devices << new_device
            json = JSON.generate(new_device)
            dialog.execute_script("onCustomDeviceApplied('#{json.gsub("'", "\\\\'")}')")

          rescue => e
            model.abort_operation rescue nil
            dialog.execute_script("onCustomDeviceError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        # --- Callback: Update Device Height — adjusts EE_Device child group Z position ---
        dialog.add_action_callback("updateDeviceHeight") do |_ctx, height_str, level_param|
          begin
            # Parse like SketchUp VCB: supports "1.2m", "120cm", "1200mm", or plain number in model units
            height_internal = height_str.to_s.strip.to_l  # Returns Length in internal inches
            height_m = height_internal.to_m               # Convert to meters for attribute storage
            level_param = level_param.to_s.strip

            # Map level parameter to device type key in SU_Electrical_Height
            device_map = {
              'Ceiling Light' => 'ceiling_lighting',
              'Wall Light'    => 'wall_lighting',
              'Switch'        => 'switch',
              'Receptacle'    => 'receptacle',
              'Load Panel'    => 'load_panel'
            }
            target_device = device_map[level_param]

            model = Sketchup.active_model
            updated_count = 0

            model.start_operation('Update Device Height', true)

            # Scan all entities in the active context
            entities_to_scan = model.active_entities.to_a
            entities_to_scan.each do |entity|
              next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
              next unless entity.valid?

              # Check if entity has SU_Electrical_Height attribute
              dict = entity.attribute_dictionary(AttributesManager::DICT_HEIGHT)
              dict ||= entity.respond_to?(:definition) ? entity.definition.attribute_dictionary(AttributesManager::DICT_HEIGHT) : nil
              next unless dict

              device_val = dict['device'].to_s

              # If a level parameter is selected, only update matching device types
              if target_device && !target_device.empty?
                next unless device_val == target_device
              end

              # Update the stored device_height attribute
              entity.set_attribute(AttributesManager::DICT_HEIGHT, 'device_height', height_m)
              if entity.respond_to?(:definition)
                entity.definition.set_attribute(AttributesManager::DICT_HEIGHT, 'device_height', height_m)
              end

              # Find and move the child group/component named "EE_Device"
              AttributesManager.update_ee_device_height(entity, height_m)
              updated_count += 1
            end

            model.commit_operation

            dialog.execute_script("onDeviceHeightUpdated(#{updated_count})")
          rescue => e
            model.abort_operation rescue nil
            dialog.execute_script("onDeviceHeightError('#{e.message.gsub("'", "\\\\'")}')")
          end
        end

        dialog.set_on_closed { @input_devices_dialog = nil }
        @input_devices_dialog = dialog
        dialog.show
      end


    end
  end
end
