# frozen_string_literal: true

module MyExtensions
  module ElectricalCalculator
    module UILogic
      
      def self.toggle_create_circuit
        if UIHelper.close_circuit_dialogs
          return
        end

        selection = Sketchup.active_model.selection
        if selection.empty?
          UIHelper.show_alert('Selection Error', 'กรุณาเลือกวัตถุอย่างน้อย 1 ชิ้น', 'warning')
          return
        end
        
        is_update_mode = false
        target_group = nil
        
        # Check if single group selected and it is a circuit selection
        if selection.count == 1 && AttributesManager.is_circuit_group?(selection[0])
          is_update_mode = true
          target_group = selection[0]
        else
          # Check if entering a group context (editing inside a circuit group?)
          # OR check if user selected items inside a group that IS a circuit?
          # The user requirement says: "Select parent group... update sum... use existing name"
          first_item_parent = selection[0].parent
          if AttributesManager.is_circuit_group?(first_item_parent)
             # If all selected items are inside this parent
             if selection.all? { |e| e.parent == first_item_parent }
                is_update_mode = true
                target_group = first_item_parent
             end
          end
        end

        # Calculate Loads (Recursive)
        # If update mode, we scan the Target Group (the whole circuit).
        # If create mode, we scan the Selection.
        scan_target = is_update_mode ? target_group.entities : selection
        
        connected_load_w, load_types = collect_loads_recursive(scan_target)
        
        if connected_load_w.zero?
           msg = is_update_mode ? 
             "ไม่พบข้อมูลโหลดในวงจร '#{target_group.name}'\nกรุณากำหนดโหลดให้วัตถุภายใน Group ก่อน" :
             "ไม่พบข้อมูลโหลดในวัตถุที่เลือก"
           UIHelper.show_alert('No Loads Found', msg, 'error')
           return
        end
        
        main_load_type = load_types.group_by{ |e| e }.max_by{ |_k, v| v.length }&.first || 'General'

        # Prepare Options for Calculator
        options = {}
        
        if is_update_mode
          # Reuse existing attributes
          existing_attrs = AttributesManager.get_all_circuit_attributes(target_group)
          options = {
            circuit_name: existing_attrs['circuit_name'],
            voltage: (existing_attrs['voltage'] || 230).to_f,
            phases: (existing_attrs['phases'] || 1).to_i,
            power_factor: (existing_attrs['power_factor'] || 0.9).to_f,
            circuit_length: (existing_attrs['circuit_length'] || 20.0).to_f,
            load_type: main_load_type,
            connected_load_w: connected_load_w
          }
          process_calculation(options, true, target_group, selection)
        else
          # Collect existing circuit names for autocomplete & auto-increment
          existing_names = Sketchup.active_model.active_entities
            .select { |e| AttributesManager.is_circuit_group?(e) }
            .map { |g| (AttributesManager.get_all_circuit_attributes(g) || {})['circuit_name'].to_s }
            .reject(&:empty?)
            .uniq
            .sort

          # Auto-increment LP-x: find highest existing LP-N and use N+1
          lp_numbers = existing_names.map { |n| n.match(/\ALP-(\d+)\z/i)&.captures&.first&.to_i }.compact
          next_lp = lp_numbers.empty? ? 1 : lp_numbers.max + 1
          default_name = "LP-#{next_lp}"

          # Prompt for parameters using Modern HTML Dialog
          defaults = [default_name, "230.0", "1", "0.9"]
          
          UIHelper.show_circuit_parameters(defaults, existing_names) do |input|
            next unless input # Handle cancel
            
            options = {
              circuit_name: input[0],
              voltage: input[1].to_f,
              phases: input[2].to_i,
              power_factor: input[3].to_f,
              circuit_length: 20.0,
              load_type: main_load_type,
              connected_load_w: connected_load_w
            }
            process_calculation(options, false, nil, selection)
          end
        end
      end
      
      def self.process_calculation(options, is_update_mode, target_group, selection)
        # Calculate
        calculator = Calculator.new(options)
        results = calculator.calculate_all 
        
        # Capture entities for Create Mode safe usage in callback
        entities_to_group = is_update_mode ? nil : selection.to_a

        UIHelper.show_circuit_update(results) do |action, new_name|
          if action == :update
            model = Sketchup.active_model
            
            # Validity Check
            if is_update_mode 
               if !target_group.valid?
                 UIHelper.show_alert('Error', 'Target group is no longer valid.', 'error')
                 next
               end
            elsif entities_to_group.any?(&:deleted?)
               UIHelper.show_alert('Error', 'Selection has changed.', 'error')
               next
            end
            
            op_name = is_update_mode ? 'Update Circuit' : 'Create Circuit'
            model.start_operation(op_name, true)
            
            group_to_process = nil
            if is_update_mode
              group_to_process = target_group
            else
              # Use captured array
              group_to_process = model.active_entities.add_group(entities_to_group)
            end
            
            # Update Name
            group_to_process.name = new_name
            results[:circuit_name] = new_name
            
            # Save Attributes
            AttributesManager.set_circuit_attributes(group_to_process, results)
            
            model.commit_operation
            
          end
        end
      end

      private

      def self.collect_loads_recursive(entities)
        total_watts = 0.0
        load_types = []
        
        entities.each do |entity|
          is_load = false
          
          # Check direct attribute (Instance or Definition via helper)
          # We don't check attribute_dictionary presence first because it might be on the Definition
          data = AttributesManager.get_load_attributes(entity)
          if data[:watts] > 0
            total_watts += data[:watts]
            load_types << data[:load_type]
            is_load = true
          end
          
          # Recurse if not a load (or traverse inside?)
          # Current logic: If it IS a load container (Group with attribs), we stop.
          # If it is NOT a load container, we look inside.
          
          unless is_load
            if entity.is_a?(Sketchup::Group)
              w, t = collect_loads_recursive(entity.entities)
              total_watts += w
              load_types.concat(t)
            elsif entity.is_a?(Sketchup::ComponentInstance)
              w, t = collect_loads_recursive(entity.definition.entities)
              total_watts += w
              load_types.concat(t)
            end
          end
        end
        
        [total_watts, load_types]
      end

    end
  end
end
