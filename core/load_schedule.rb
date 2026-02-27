# frozen_string_literal: true

module MyExtensions
  module ElectricalCalculator
    module UILogic

      # -----------------------------------------------------------
      # Transform raw circuit attributes into the format expected
      # by the load_schedule.html table's populateTable() function.
      # -----------------------------------------------------------
      def self.get_all_circuits_data
        # Map to include the group object itself for attribute saving
        raw_data = Sketchup.active_model.active_entities
          .select { |e| AttributesManager.is_circuit_group?(e) }
          .map do |group| 
            attrs = AttributesManager.get_all_circuit_attributes(group)
            attrs[:entity_group] = group # Store group reference
            attrs
          end.compact

        # Sort by group name for consistent ordering
        raw_data.sort_by! { |h| h['circuit_name'].to_s }

        # Phase assignment counter for single-phase round-robin (A→B→C)
        phase_counter = 0
        circuit_number = 0

        transformed = raw_data.map do |attrs|
          circuit_number += 1

          # --- Basic fields ---
          name         = attrs['circuit_name'].to_s
          phases       = (attrs['phases'] || 1).to_i
          voltage      = (attrs['voltage'] || 230).to_f
          pf           = (attrs['power_factor'] || 0.9).to_f
          breaker_at   = attrs['breaker_at'] || '-'
          wire_sqmm    = attrs['wire_size_sqmm']
          
          # --- Persistent Color ---
          text_color = attrs['schedule_text_color']
          unless text_color
            text_color = generate_random_color
            # Save persistently to the group
            AttributesManager.set_circuit_attributes(attrs[:entity_group], { 'schedule_text_color' => text_color })
          end
          demand_va    = (attrs['demand_load_va'] || 0).to_f
          load_w       = (attrs['connected_load_w'] || 0).to_f

          # --- Wire size formatting ---
          # Format: "L+N : 2-1/Cx{size}" for 1Ø, "3-1/Cx{size}\nG : 1-1/Cx{size}" for 3Ø
          if wire_sqmm
            if phases == 1
              wire_size_str = "L+N : 2-1/Cx#{wire_sqmm}\nG : 1-1/Cx#{wire_sqmm}"
            else
              wire_size_str = "3-1/Cx#{wire_sqmm}\nG : 1-1/Cx#{wire_sqmm}"
            end
          else
            wire_size_str = '-'
          end

          # --- Breaker pole ---
          breaker_pole = phases

          # --- Wire type (default THW for IEC01 standard) ---
          wire_type = 'THW'

          # --- Conduit (auto-estimate based on wire size) ---
          conduit = estimate_conduit(wire_sqmm, phases)

          # --- Phase VA assignment ---
          va_a = ''
          va_b = ''
          va_c = ''

          display_va = demand_va > 0 ? demand_va.round(0) : load_w.round(0)

          if phases == 3
            # 3-phase: split equally across all phases
            per_phase = (display_va / 3.0).round(0)
            va_a = per_phase
            va_b = per_phase
            va_c = per_phase
          else
            # 1-phase: round-robin assignment A→B→C
            phase_idx = phase_counter % 3
            phase_counter += 1
            case phase_idx
            when 0 then va_a = display_va.round(0)
            when 1 then va_b = display_va.round(0)
            when 2 then va_c = display_va.round(0)
            end
          end

          # --- Build output hash ---
          {
            'circuit_no'   => circuit_number,
            'name'         => name,
            'wire_size'    => wire_size_str,
            'wire_type'    => wire_type,
            'conduit'      => conduit,
            'breaker_pole' => breaker_pole,
            'breaker_at'   => breaker_at,
            'va_a'         => va_a,
            'va_b'         => va_b,
            'va_c'         => va_c,
            # Keep extra info for CSV export
            'voltage'            => voltage,
            'power_factor'       => pf,
            'connected_load_w'   => load_w,
            'demand_load_va'     => demand_va,
            'design_current_a'   => attrs['design_current_a'],
            'voltage_drop_pct'   => attrs['voltage_drop_percent'],
            'design_current_a'   => attrs['design_current_a'],
            'voltage_drop_pct'   => attrs['voltage_drop_percent'],
            'load_type'          => attrs['load_type'],
            'text_color'         => text_color, # Pass color to HTML
            'entity_id'          => attrs[:entity_group].persistent_id # Pass ID for selection
          }
        end

        # Sanitize any Infinity/NaN values
        transformed.each do |circuit_hash|
          circuit_hash.each do |key, value|
            if value.is_a?(Float) && (value.infinite? || value.nan?)
              circuit_hash[key] = "N/A"
            end
          end
        end

        transformed
      end

      # -----------------------------------------------------------
      # Estimate conduit size based on wire size and phases
      # -----------------------------------------------------------
      def self.estimate_conduit(wire_sqmm, phases)
        return '-' unless wire_sqmm
        sqmm = wire_sqmm.to_f
        if phases == 1
          if sqmm <= 4.0
            '1/2" PVC'
          elsif sqmm <= 10.0
            '3/4" PVC'
          else
            '1" PVC'
          end
        else
          if sqmm <= 4.0
            '3/4" PVC'
          elsif sqmm <= 10.0
            '1" PVC'
          else
            '1-1/4" PVC'
          end
        end
      end
      
      # -----------------------------------------------------------
      # Generate random dark color (Hex) for persistent schedule text
      # -----------------------------------------------------------
      def self.generate_random_color
        # HSL-like logic converted to RGB hex
        # H: 0-360, S: 70-100%, L: 20-45% (Dark for white BG)
        h = rand(360) / 360.0
        s = rand(30..100) / 100.0
        l = rand(20..45) / 100.0
        
        # Simple HSL to RGB conversion
        c = (1 - (2 * l - 1).abs) * s
        x = c * (1 - ((h * 6) % 2 - 1).abs)
        m = l - c / 2.0
        
        r, g, b = 0, 0, 0
        if h < 1/6.0
          r, g, b = c, x, 0
        elsif h < 2/6.0
          r, g, b = x, c, 0
        elsif h < 3/6.0
          r, g, b = 0, c, x
        elsif h < 4/6.0
          r, g, b = 0, x, c
        elsif h < 5/6.0
          r, g, b = x, 0, c
        else
          r, g, b = c, 0, x
        end
        
        r = ((r + m) * 255).round
        g = ((g + m) * 255).round
        b = ((b + m) * 255).round
        
        sprintf("#%02X%02X%02X", r, g, b)
      end

      def self.export_data_to_csv
        data = get_all_circuits_data; return UI.messagebox('ไม่พบข้อมูลวงจรให้ส่งออก') if data.empty?
        file_path = UI.savepanel("ส่งออกตารางโหลดเป็น CSV", "", "load_schedule.csv"); return unless file_path
        begin
          CSV.open(file_path, "wb", headers: data.first.keys, write_headers: true) do |csv|
            data.each { |row| csv << row }
          end; UI.messagebox("ส่งออกสำเร็จ:\n#{file_path}")
        rescue => e; UI.messagebox("เกิดข้อผิดพลาดในการส่งออก: #{e.message}"); end
      end

      def self.toggle_load_schedule
        if @dialog
          @dialog.close
          return
        end
        @dialog = create_dialog
        @dialog.show
      end

      private

      def self.create_dialog
        dialog = UI::HtmlDialog.new({ dialog_title: "ตารางรายการโหลด - Electrical Load Schedule", scrollable: true, resizable: true,
                                      width: 1200, height: 800, style: UI::HtmlDialog::STYLE_DIALOG,
                                      preferences_key: 'com.electrical.load_schedule' })
        
        html_path = File.join(EXTENSION_ROOT, 'html', 'load_schedule.html')
        
        dialog.set_file(html_path)
        
        dialog.add_action_callback("requestData") do |_action_context, _params|
          dialog.execute_script("populateTable(#{get_all_circuits_data.to_json})")
        end
        
        dialog.add_action_callback("resizeDialog") do |_ctx, width, height|
          begin
            w = width.to_i
            h = height.to_i
            final_w = [w + 20, 600].max
            final_h = [h + 2, 200].max
            dialog.set_size(final_w, final_h)
          rescue => e
            puts "resizeDialog error: #{e.message}"
          end
        end

        dialog.add_action_callback("exportCSV") do |_action_context, _params|
          export_data_to_csv
        end

        dialog.add_action_callback("toggleCircuit") do |_ctx, id, selected|
          model = Sketchup.active_model
          model.selection.clear
          
          if selected
            entity = model.active_entities.find { |e| e.persistent_id == id.to_i }
            entity ||= model.find_entity_by_persistent_id(id.to_i)
            model.selection.add(entity) if entity
          end
        end
        
        dialog.set_on_closed { @dialog = nil }
        dialog
      end
    end
  end
end

