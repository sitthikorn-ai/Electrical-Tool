# frozen_string_literal: true

module MyExtensions
  module ElectricalCalculator
    module UILogic

      # -----------------------------------------------------------
      # Transform raw circuit attributes into the format expected
      # by the load_schedule.html table's populateTable() function.
      # Supports 3-phase circuits occupying 3 consecutive slots.
      # -----------------------------------------------------------
      def self.get_all_circuits_data
        raw_data = Sketchup.active_model.active_entities
          .select { |e| AttributesManager.is_circuit_group?(e) }
          .map do |group|
            attrs = AttributesManager.get_all_circuit_attributes(group)
            attrs[:entity_group] = group
            attrs
          end.compact

        # Check for saved arrangement
        has_saved = raw_data.any? { |h| h['schedule_slot'] }
        if has_saved
          raw_data.sort_by! { |h| [h['schedule_slot'] ? 0 : 1, h['schedule_slot'].to_i, h['circuit_name'].to_s] }
        else
          raw_data.sort_by! { |h| h['circuit_name'].to_s }
        end

        # Collect occupied slots from saved arrangement
        occupied = {}
        if has_saved
          raw_data.each do |h|
            next unless h['schedule_slot']
            s = h['schedule_slot'].to_i
            p = (h['phases'] || 1).to_i
            if p == 3
              [s, s + 2, s + 4].each { |sl| occupied[sl] = true }
            else
              occupied[s] = true
            end
          end
        end

        # --- Slot allocation ---
        # Odd slots = left side (1,3,5,...,29), Even slots = right side (2,4,6,...,30)
        # Phase per slot: ((slot-1)/2) % 3  →  0=L1, 1=L2, 2=L3
        #   1,2→L1  3,4→L2  5,6→L3  7,8→L1  9,10→L2  11,12→L3 ...
        # 3-phase circuits use 3 consecutive same-side slots (e.g. 1,3,5 or 2,4,6)
        left_next  = 1   # next available odd slot
        right_next = 2   # next available even slot
        use_left   = true

        transformed = []

        raw_data.each do |attrs|
          name       = attrs['circuit_name'].to_s
          phases     = (attrs['phases'] || 1).to_i
          voltage    = (attrs['voltage'] || 230).to_f
          pf         = (attrs['power_factor'] || 0.9).to_f
          breaker_at = attrs['breaker_at'] || '-'
          wire_sqmm  = attrs['wire_size_sqmm']

          text_color = attrs['schedule_text_color']
          unless text_color
            text_color = generate_random_color
            AttributesManager.set_circuit_attributes(attrs[:entity_group], { 'schedule_text_color' => text_color })
          end

          demand_va  = (attrs['demand_load_va'] || 0).to_f
          load_w     = (attrs['connected_load_w'] || 0).to_f
          display_va = demand_va > 0 ? demand_va.round(0) : load_w.round(0)

          if wire_sqmm
            wire_size_str = phases == 1 ?
              "L+N : 2-1/Cx#{wire_sqmm}\nG : 1-1/Cx#{wire_sqmm}" :
              "3-1/Cx#{wire_sqmm}, G : 1-1/Cx#{wire_sqmm}"
          else
            wire_size_str = '-'
          end

          breaker_pole = phases
          wire_type    = 'THW'
          conduit      = estimate_conduit(wire_sqmm, phases)
          entity_id    = attrs[:entity_group].persistent_id

          common = {
            'name'         => name,       'wire_size'    => wire_size_str,
            'wire_type'    => wire_type,   'conduit'      => conduit,
            'breaker_pole' => breaker_pole,'breaker_at'   => breaker_at,
            'voltage'      => voltage,     'power_factor' => pf,
            'connected_load_w' => load_w,  'demand_load_va' => demand_va,
            'design_current_a' => attrs['design_current_a'],
            'voltage_drop_pct' => attrs['voltage_drop_percent'],
            'load_type'    => attrs['load_type'],
            'text_color'   => text_color,  'entity_id'    => entity_id
          }

          if phases == 3
            # --- 3-phase: allocate 3 consecutive same-side slots (must start at R-phase) ---
            per_phase = (display_va / 3.0).round(0)
            slots = nil

            if attrs['schedule_slot']
              first_slot = attrs['schedule_slot'].to_i
              slots = [first_slot, first_slot + 2, first_slot + 4]
            else
              # Skip occupied slots
              left_next += 2 while occupied[left_next] && left_next <= 29
              right_next += 2 while occupied[right_next] && right_next <= 30

              left_r  = next_r_phase_slot(left_next)
              right_r = next_r_phase_slot(right_next)

              if use_left && left_r + 4 <= 30
                left_next = left_r
                slots = [left_next, left_next + 2, left_next + 4]
                left_next += 6
              elsif right_r + 4 <= 30
                right_next = right_r
                slots = [right_next, right_next + 2, right_next + 4]
                right_next += 6
              elsif left_r + 4 <= 30
                left_next = left_r
                slots = [left_next, left_next + 2, left_next + 4]
                left_next += 6
              end
            end
            next unless slots

            span_id = "3p_#{entity_id}"
            slots.each_with_index do |slot, idx|
              va_a = idx == 0 ? per_phase : ''
              va_b = idx == 1 ? per_phase : ''
              va_c = idx == 2 ? per_phase : ''
              transformed << common.merge(
                'circuit_no'    => slot,
                'va_a' => va_a, 'va_b' => va_b, 'va_c' => va_c,
                'span_group'    => span_id,
                'span_position' => idx,
                'span_size'     => 3
              )
            end
            use_left = !use_left
          else
            # --- 1-phase: allocate 1 slot ---
            slot = nil
            if attrs['schedule_slot']
              slot = attrs['schedule_slot'].to_i
            else
              # Skip occupied slots
              left_next += 2 while occupied[left_next] && left_next <= 29
              right_next += 2 while occupied[right_next] && right_next <= 30

              if use_left && left_next <= 29
                slot = left_next; left_next += 2
              elsif right_next <= 30
                slot = right_next; right_next += 2
              elsif left_next <= 29
                slot = left_next; left_next += 2
              end
            end
            next unless slot

            phase_idx = ((slot - 1) / 2) % 3
            va_a = phase_idx == 0 ? display_va.round(0) : ''
            va_b = phase_idx == 1 ? display_va.round(0) : ''
            va_c = phase_idx == 2 ? display_va.round(0) : ''

            transformed << common.merge(
              'circuit_no'    => slot,
              'va_a' => va_a, 'va_b' => va_b, 'va_c' => va_c,
              'span_group'    => nil,
              'span_position' => 0,
              'span_size'     => 1
            )
            use_left = !use_left
          end
        end

        # Sanitize any Infinity/NaN values
        transformed.each do |h|
          h.each { |k, v| h[k] = "N/A" if v.is_a?(Float) && (v.infinite? || v.nan?) }
        end

        transformed
      end

      # -----------------------------------------------------------
      # Swap two circuit slots by their circuit_no values.
      # For 3-phase circuits, swaps the entire 3-slot group.
      # Returns refreshed data for the HTML table.
      # -----------------------------------------------------------
      def self.swap_circuits_data(data, slot_a, slot_b)
        a_entries = data.select { |d| d['circuit_no'] == slot_a }
        b_entries = data.select { |d| d['circuit_no'] == slot_b }
        return data if a_entries.empty? && b_entries.empty?

        # Collect full span groups if applicable
        a_group = a_entries.first && a_entries.first['span_group']
        b_group = b_entries.first && b_entries.first['span_group']
        a_all = a_group ? data.select { |d| d['span_group'] == a_group } : a_entries
        b_all = b_group ? data.select { |d| d['span_group'] == b_group } : b_entries

        # Handle swap with SPACE (one side empty)
        if a_all.empty? && !b_all.empty?
          move_group_to_slot(b_all, slot_a)
          return data
        elsif !a_all.empty? && b_all.empty?
          move_group_to_slot(a_all, slot_b)
          return data
        end

        a_slots = a_all.map { |d| d['circuit_no'] }.sort
        b_slots = b_all.map { |d| d['circuit_no'] }.sort

        return data if a_slots.size != b_slots.size

        # Exchange slot numbers
        a_all.each_with_index { |d, i| d['circuit_no'] = b_slots[i] }
        b_all.each_with_index { |d, i| d['circuit_no'] = a_slots[i] }

        # Reassign phase VA and update LP-N prefix based on new slot
        # For span groups, use the first (lowest) slot for the LP-N prefix
        a_first = a_all.map { |d| d['circuit_no'] }.min
        b_first = b_all.map { |d| d['circuit_no'] }.min
        a_all.each do |d|
          reassign_phase_va(d) if d['span_size'].to_i <= 1
          name_slot = d['span_size'].to_i > 1 ? a_first : d['circuit_no']
          d['name'] = d['name'].to_s.sub(/\ALP-\d+/i, "LP-#{name_slot}")
        end
        b_all.each do |d|
          reassign_phase_va(d) if d['span_size'].to_i <= 1
          name_slot = d['span_size'].to_i > 1 ? b_first : d['circuit_no']
          d['name'] = d['name'].to_s.sub(/\ALP-\d+/i, "LP-#{name_slot}")
        end

        data
      end

      # -----------------------------------------------------------
      # Auto-balance: try to minimize phase imbalance by swapping
      # single-phase circuits between slots of different phases.
      # -----------------------------------------------------------
      def self.auto_balance_data(data)
        single = data.select { |d| d['span_size'].to_i <= 1 }
        return data if single.size < 2

        10.times do
          totals = phase_totals(data)
          max_phase = totals.each_with_index.max_by { |v, _| v }[1]
          min_phase = totals.each_with_index.min_by { |v, _| v }[1]
          break if (totals[max_phase] - totals[min_phase]) < 100

          # Find a circuit on the heavy phase and one on the light phase
          heavy = single.select { |d| phase_of(d) == max_phase && circuit_va(d) > 0 }
          light = single.select { |d| phase_of(d) == min_phase && circuit_va(d) > 0 }
          break if heavy.empty? || light.empty?

          h = heavy.max_by { |d| circuit_va(d) }
          l = light.min_by { |d| circuit_va(d) }

          # Swap their slot numbers
          h_slot = h['circuit_no']; l_slot = l['circuit_no']
          h['circuit_no'] = l_slot; l['circuit_no'] = h_slot

          # Reassign phase VA based on new slot
          reassign_phase_va(h); reassign_phase_va(l)
        end

        data
      end

      def self.phase_totals(data)
        t = [0, 0, 0]
        data.each do |d|
          t[0] += d['va_a'].to_i
          t[1] += d['va_b'].to_i
          t[2] += d['va_c'].to_i
        end
        t
      end

      def self.phase_of(d)
        return 0 if d['va_a'].to_i > 0
        return 1 if d['va_b'].to_i > 0
        return 2 if d['va_c'].to_i > 0
        0
      end

      def self.circuit_va(d)
        [d['va_a'].to_i, d['va_b'].to_i, d['va_c'].to_i].max
      end

      def self.reassign_phase_va(d)
        va = circuit_va(d)
        slot = d['circuit_no']
        idx = ((slot - 1) / 2) % 3
        d['va_a'] = idx == 0 ? va : ''
        d['va_b'] = idx == 1 ? va : ''
        d['va_c'] = idx == 2 ? va : ''
      end

      # Move a circuit group (1-phase or 3-phase) to a new target slot.
      # For 3-phase groups, assigns consecutive same-side slots (target, target+2, target+4).
      def self.move_group_to_slot(group, target_slot)
        group.sort_by! { |d| d['circuit_no'] }
        if group.size > 1
          # Multi-slot (3-phase) group: assign consecutive same-side slots
          new_slots = group.each_with_index.map { |_, i| target_slot + (i * 2) }
          return if new_slots.last > 30
          group.each_with_index do |d, i|
            d['circuit_no'] = new_slots[i]
            d['span_position'] = i
            d['name'] = d['name'].to_s.sub(/\ALP-\d+/i, "LP-#{target_slot}")
          end
        else
          group.each do |d|
            d['circuit_no'] = target_slot
            reassign_phase_va(d) if d['span_size'].to_i <= 1
            d['name'] = d['name'].to_s.sub(/\ALP-\d+/i, "LP-#{d['circuit_no']}")
          end
        end
      end

      def self.next_r_phase_slot(slot)
        slot += 2 while ((slot - 1) / 2) % 3 != 0
        slot
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

      # Cache last data for swap/balance operations within the dialog session
      @last_data = nil

      def self.create_dialog
        dialog = UI::HtmlDialog.new({ dialog_title: "ตารางรายการโหลด - Electrical Load Schedule", scrollable: true, resizable: true,
                                      width: 800, height: 800, style: UI::HtmlDialog::STYLE_DIALOG,
                                      preferences_key: 'com.electrical.load_schedule' })
        
        html_path = File.join(EXTENSION_ROOT, 'html', 'load_schedule.html')
        
        dialog.set_file(html_path)
        
        dialog.add_action_callback("requestData") do |_action_context, _params|
          @last_data = get_all_circuits_data
          dialog.execute_script("populateTable(#{@last_data.to_json})")
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

        dialog.add_action_callback("swapCircuits") do |_ctx, slot_a, slot_b|
          if @last_data
            @last_data = swap_circuits_data(@last_data, slot_a.to_i, slot_b.to_i)
            dialog.execute_script("populateTable(#{@last_data.to_json})")
          end
        end

        dialog.add_action_callback("autoBalance") do |_ctx|
          if @last_data
            @last_data = auto_balance_data(@last_data)
            dialog.execute_script("populateTable(#{@last_data.to_json})")
          end
        end

        dialog.add_action_callback("updateNames") do |_ctx|
          if @last_data
            model = Sketchup.active_model
            model.start_operation('Update Circuit Names', true)

            # Pre-compute all slots for each span_group (sorted ascending)
            span_slots = {}
            @last_data.each do |d|
              sg = d['span_group']
              next unless sg
              span_slots[sg] ||= []
              span_slots[sg] << d['circuit_no'].to_i
            end
            span_slots.each_value { |v| v.sort!.uniq! }

            updated_entities = {}
            @last_data.each do |d|
              sg = d['span_group']
              if sg && span_slots[sg] && span_slots[sg].size > 1
                lp_prefix = "LP-#{span_slots[sg].join('-')}"
              else
                lp_prefix = "LP-#{d['circuit_no']}"
              end

              old_name = d['name'].to_s
              desc = old_name.sub(/\ALP-[\d\-]+\s*/i, '').strip
              new_name = desc.empty? ? lp_prefix : "#{lp_prefix} #{desc}"
              d['name'] = new_name

              # Only update entity once per entity_id (skip duplicates from 3-phase)
              eid = d['entity_id']
              next unless eid
              next if updated_entities[eid]
              updated_entities[eid] = true

              entity = model.active_entities.find { |e| e.respond_to?(:persistent_id) && e.persistent_id == eid.to_i }
              entity ||= model.find_entity_by_persistent_id(eid.to_i)
              if entity
                entity.name = new_name
                AttributesManager.set_circuit_attributes(entity, { 'circuit_name' => new_name })
              end
            end
            model.commit_operation
            dialog.execute_script("populateTable(#{@last_data.to_json})")
          end
        end
        
        dialog.add_action_callback("saveArrangement") do |_ctx|
          if @last_data
            model = Sketchup.active_model
            model.start_operation('Save Circuit Arrangement', true)

            # Group by entity_id to find the first (lowest) slot for each circuit
            by_entity = {}
            @last_data.each do |d|
              eid = d['entity_id']
              next unless eid
              slot = d['circuit_no'].to_i
              by_entity[eid] = slot if !by_entity[eid] || slot < by_entity[eid]
            end

            by_entity.each do |eid, first_slot|
              entity = model.active_entities.find { |e| e.respond_to?(:persistent_id) && e.persistent_id == eid.to_i }
              entity ||= model.find_entity_by_persistent_id(eid.to_i)
              next unless entity
              AttributesManager.set_circuit_attributes(entity, { 'schedule_slot' => first_slot })
            end

            model.commit_operation
            dialog.execute_script("onSaveComplete()")
          end
        end

        dialog.set_on_closed { @dialog = nil; @last_data = nil }
        dialog
      end
    end
  end
end

