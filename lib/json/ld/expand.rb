# -*- encoding: utf-8 -*-
# frozen_string_literal: true
require 'set'

module JSON::LD
  ##
  # Expand module, used as part of API
  module Expand
    include Utils

    # The following constant is used to reduce object allocations
    CONTAINER_INDEX_ID_TYPE = Set.new(%w(@index @id @type)).freeze
    CONTAINER_GRAPH_INDEX = %w(@graph @index).freeze
    CONTAINER_INDEX = %w(@index).freeze
    CONTAINER_ID = %w(@id).freeze
    CONTAINER_LIST = %w(@list).freeze
    CONTAINER_TYPE = %w(@type).freeze
    CONTAINER_GRAPH_ID = %w(@graph @id).freeze
    KEYS_VALUE_LANGUAGE_TYPE_INDEX = %w(@value @language @type @index).freeze
    KEYS_SET_LIST_INDEX = %w(@set @list @index).freeze

    ##
    # Expand an Array or Object given an active context and performing local context expansion.
    #
    # @param [Array, Hash] input
    # @param [String] active_property
    # @param [Context] context
    # @param [Boolean] ordered (true)
    #   Ensure output objects have keys ordered properly
    # @param [Boolean] framing (false)
    #   Special rules for expanding a frame
    # @return [Array<Hash{String => Object}>]
    def expand(input, active_property, context, ordered: false, framing: false)
      #log_debug("expand") {"input: #{input.inspect}, active_property: #{active_property.inspect}, context: #{context.inspect}"}
      framing = false if active_property == '@default'
      result = case input
      when Array
        # If element is an array,
        is_list = context.container(active_property) == CONTAINER_LIST
        value = input.each_with_object([]) do |v, memo|
          # Initialize expanded item to the result of using this algorithm recursively, passing active context, active property, and item as element.
          v = expand(v, active_property, context, ordered: ordered, framing: framing)

          # If the active property is @list or its container mapping is set to @list and v is an array, change it to a list object
          v = {"@list" => v} if is_list && v.is_a?(Array)

          case v
          when nil then nil
          when Array then memo.concat(v)
          else            memo << v
          end
        end

        value
      when Hash
        # If element contains the key @context, set active context to the result of the Context Processing algorithm, passing active context and the value of the @context key as local context.
        if input.has_key?('@context')
          context = context.parse(input.delete('@context'))
          #log_debug("expand") {"context: #{context.inspect}"}
        end

        output_object = {}

        # See if keys mapping to @type have terms with a local context
        input.each_pair do |key, val|
          next unless context.expand_iri(key, vocab: true) == '@type'
          Array(val).sort.each do |term|
            term_context = context.term_definitions[term].context if context.term_definitions[term]
            context = term_context ? context.parse(term_context) : context
          end
        end

        # Process each key and value in element. Ignores @nesting content
        expand_object(input, active_property, context, output_object, ordered: ordered, framing: framing)

        #log_debug("output object") {output_object.inspect}

        # If result contains the key @value:
        if value?(output_object)
          unless (output_object.keys - KEYS_VALUE_LANGUAGE_TYPE_INDEX).empty? &&
                 !(output_object.key?('@language') && output_object.key?('@type'))
            # The result must not contain any keys other than @value, @language, @type, and @index. It must not contain both the @language key and the @type key. Otherwise, an invalid value object error has been detected and processing is aborted.
            raise JsonLdError::InvalidValueObject,
            "value object has unknown keys: #{output_object.inspect}"
          end

          output_object.delete('@language') if output_object.key?('@language') && Array(output_object['@language']).empty?
          output_object.delete('@type') if output_object.key?('@type') && Array(output_object['@type']).empty?

          # If the value of result's @value key is null, then set result to null.
          ary = Array(output_object['@value'])
          return nil if ary.empty?

          if context.processingMode == 'json-ld-1.1' && output_object['@type'] == '@json'
            # Any value of @value is okay if @type: @json
          elsif !ary.all? {|v| v.is_a?(String) || v.is_a?(Hash) && v.empty?} && output_object.has_key?('@language')
            # Otherwise, if the value of result's @value member is not a string and result contains the key @language, an invalid language-tagged value error has been detected (only strings can be language-tagged) and processing is aborted.
            raise JsonLdError::InvalidLanguageTaggedValue,
                  "when @language is used, @value must be a string: #{output_object.inspect}"
          elsif !Array(output_object['@type']).all? {|t|
                  t.is_a?(String) && RDF::URI(t).absolute? && !t.start_with?('_:') ||
                  t.is_a?(Hash) && t.empty?}
            # Otherwise, if the result has a @type member and its value is not an IRI, an invalid typed value error has been detected and processing is aborted.
            raise JsonLdError::InvalidTypedValue,
                  "value of @type must be an IRI: #{output_object.inspect}"
          end
        elsif !output_object.fetch('@type', []).is_a?(Array)
          # Otherwise, if result contains the key @type and its associated value is not an array, set it to an array containing only the associated value.
          output_object['@type'] = [output_object['@type']]
        elsif output_object.key?('@set') || output_object.key?('@list')
          # Otherwise, if result contains the key @set or @list:
          # The result must contain at most one other key and that key must be @index. Otherwise, an invalid set or list object error has been detected and processing is aborted.
          raise JsonLdError::InvalidSetOrListObject,
                "@set or @list may only contain @index: #{output_object.keys.inspect}" unless
                (output_object.keys - KEYS_SET_LIST_INDEX).empty?

          # If result contains the key @set, then set result to the key's associated value.
          return output_object['@set'] if output_object.key?('@set')
        end

        # If result contains only the key @language, set result to null.
        return nil if output_object.length == 1 && output_object.key?('@language')

        # If active property is null or @graph, drop free-floating values as follows:
        if (active_property || '@graph') == '@graph' &&
          (output_object.key?('@value') || output_object.key?('@list') ||
           (output_object.keys - CONTAINER_ID).empty? && !framing)
          #log_debug(" =>") { "empty top-level: " + output_object.inspect}
          return nil
        end

        # Re-order result keys if ordering
        if ordered
          output_object.keys.sort.each_with_object({}) {|kk, memo| memo[kk] = output_object[kk]}
        else
          output_object
        end
      else
        # Otherwise, unless the value is a number, expand the value according to the Value Expansion rules, passing active property.
        return nil if input.nil? || active_property.nil? || active_property == '@graph'
        context.expand_value(active_property, input, log_depth: @options[:log_depth])
      end

      #log_debug {" => #{result.inspect}"}
      result
    end

  private

    # Expand each key and value of element adding them to result
    def expand_object(input, active_property, context, output_object, ordered:, framing:)
      nests = []

      input_type = Array(input.detect do |k, v|
        context.expand_iri(k, vocab: true, quiet: true) == '@type'
      end).last
      input_type = context.expand_iri(input_type, vocab: true, quiet: true) if input_type

      # Then, proceed and process each property and value in element as follows:
      keys = ordered ? input.keys.sort : input.keys
      keys.each do |key|
        # For each key and value in element, ordered lexicographically by key:
        value = input[key]
        expanded_property = context.expand_iri(key, vocab: true, quiet: true)

        # If expanded property is null or it neither contains a colon (:) nor it is a keyword, drop key by continuing to the next key.
        next if expanded_property.is_a?(RDF::URI) && expanded_property.relative?
        expanded_property = expanded_property.to_s if expanded_property.is_a?(RDF::Resource)

        #log_debug("expand property") {"ap: #{active_property.inspect}, expanded: #{expanded_property.inspect}, value: #{value.inspect}"}

        if expanded_property.nil?
          #log_debug(" => ") {"skip nil property"}
          next
        end

        if KEYWORDS.include?(expanded_property)
          # If active property equals @reverse, an invalid reverse property map error has been detected and processing is aborted.
          raise JsonLdError::InvalidReversePropertyMap,
                "@reverse not appropriate at this point" if active_property == '@reverse'

          # If result has already an expanded property member, an colliding keywords error has been detected and processing is aborted.
          raise JsonLdError::CollidingKeywords,
                "#{expanded_property} already exists in result" if output_object.has_key?(expanded_property)

          expanded_value = case expanded_property
          when '@id'
            # If expanded property is @id and value is not a string, an invalid @id value error has been detected and processing is aborted
            e_id = case value
            when String
              context.expand_iri(value, documentRelative: true, quiet: true).to_s
            when Array
              # Framing allows an array of IRIs, and always puts values in an array
              raise JsonLdError::InvalidIdValue,
                    "value of @id must be a string unless framing: #{value.inspect}" unless framing
              context.expand_iri(value, documentRelative: true, quiet: true).to_s
              value.map do |v|
                raise JsonLdError::InvalidTypeValue,
                      "@id value must be a string or array of strings for framing: #{v.inspect}" unless v.is_a?(String)
                context.expand_iri(v, documentRelative: true, quiet: true,).to_s
              end
            when Hash
              raise JsonLdError::InvalidIdValue,
                    "value of @id must be a string unless framing: #{value.inspect}" unless framing
              raise JsonLdError::InvalidTypeValue,
                    "value of @id must be a an empty object for framing: #{value.inspect}" unless
                    value.empty?
              [{}]
            else
              raise JsonLdError::InvalidIdValue,
                    "value of @id must be a string or hash if framing: #{value.inspect}"
            end

            # Use array form if framing
            if framing
              as_array(e_id)
            else
              e_id
            end
          when '@type'
            # If expanded property is @type and value is neither a string nor an array of strings, an invalid type value error has been detected and processing is aborted. Otherwise, set expanded value to the result of using the IRI Expansion algorithm, passing active context, true for vocab, and true for document relative to expand the value or each of its items.
            #log_debug("@type") {"value: #{value.inspect}"}
            e_type = case value
            when Array
              value.map do |v|
                raise JsonLdError::InvalidTypeValue,
                      "@type value must be a string or array of strings: #{v.inspect}" unless v.is_a?(String)
                context.expand_iri(v, vocab: true, documentRelative: true, quiet: true).to_s
              end
            when String
              context.expand_iri(value, vocab: true, documentRelative: true, quiet: true).to_s
            when Hash
              # For framing
              raise JsonLdError::InvalidTypeValue,
                    "@type value must be a an empty object for framing: #{value.inspect}" unless
                    value.empty? && framing
              [{}]
            else
              raise JsonLdError::InvalidTypeValue,
                    "@type value must be a string or array of strings: #{value.inspect}"
            end

            # Use array form if framing
            if framing
              as_array(e_type)
            else
              e_type
            end
          when '@graph'
            # If expanded property is @graph, set expanded value to the result of using this algorithm recursively passing active context, @graph for active property, and value for element.
            value = expand(value, '@graph', context, ordered: ordered, framing: framing)
            as_array(value)
          when '@value'
            # If expanded property is @value and input contains @type: json, accept any value.
            # If expanded property is @value and value is not a scalar or null, an invalid value object value error has been detected and processing is aborted. (In 1.1, @value can have any JSON value of @type is @json or the property coerces to @json).
            # Otherwise, set expanded value to value. If expanded value is null, set the @value member of result to null and continue with the next key from element. Null values need to be preserved in this case as the meaning of an @type member depends on the existence of an @value member.
            # If framing, always use array form, unless null
            if context.processingMode == 'json-ld-1.1' && input_type == '@json'
              value
            else
              case value
              when String, TrueClass, FalseClass, Numeric then (framing ? [value] : value)
              when nil
                output_object['@value'] = nil
                next;
              when Array
                raise JsonLdError::InvalidValueObjectValue,
                      "@value value may not be an array unless framing: #{value.inspect}" unless framing
                value
              when Hash
                raise JsonLdError::InvalidValueObjectValue,
                      "@value value must be a an empty object for framing: #{value.inspect}" unless
                      value.empty? && framing
                [value]
              else
                raise JsonLdError::InvalidValueObjectValue,
                      "Value of #{expanded_property} must be a scalar or null: #{value.inspect}"
              end
            end
          when '@language'
            # If expanded property is @language and value is not a string, an invalid language-tagged string error has been detected and processing is aborted. Otherwise, set expanded value to lowercased value.
            # If framing, always use array form, unless null
            case value
            when String then (framing ? [value.downcase] : value.downcase)
            when Array
              raise JsonLdError::InvalidLanguageTaggedString,
                    "@language value may not be an array unless framing: #{value.inspect}" unless framing
              value.map(&:downcase)
            when Hash
              raise JsonLdError::InvalidLanguageTaggedString,
                    "@language value must be a an empty object for framing: #{value.inspect}" unless
                    value.empty? && framing
              [value]
            else
              raise JsonLdError::InvalidLanguageTaggedString,
                    "Value of #{expanded_property} must be a string: #{value.inspect}"
            end
          when '@index'
            # If expanded property is @index and value is not a string, an invalid @index value error has been detected and processing is aborted. Otherwise, set expanded value to value.
            raise JsonLdError::InvalidIndexValue,
                  "Value of @index is not a string: #{value.inspect}" unless value.is_a?(String)
            value
          when '@list'
            # If expanded property is @list:

            # If active property is null or @graph, continue with the next key from element to remove the free-floating list.
            next if (active_property || '@graph') == '@graph'

            # Otherwise, initialize expanded value to the result of using this algorithm recursively passing active context, active property, and value for element.
            value = expand(value, active_property, context, ordered: ordered, framing: framing)

            # Spec FIXME: need to be sure that result is an array
            value = as_array(value)

            value
          when '@set'
            # If expanded property is @set, set expanded value to the result of using this algorithm recursively, passing active context, active property, and value for element.
            expand(value, active_property, context, ordered: ordered, framing: framing)
          when '@reverse'
            # If expanded property is @reverse and value is not a JSON object, an invalid @reverse value error has been detected and processing is aborted.
            raise JsonLdError::InvalidReverseValue,
                  "@reverse value must be an object: #{value.inspect}" unless value.is_a?(Hash)

            # Otherwise
            # Initialize expanded value to the result of using this algorithm recursively, passing active context, @reverse as active property, and value as element.
            value = expand(value, '@reverse', context, ordered: ordered, framing: framing)

            # If expanded value contains an @reverse member, i.e., properties that are reversed twice, execute for each of its property and item the following steps:
            if value.has_key?('@reverse')
              #log_debug("@reverse") {"double reverse: #{value.inspect}"}
              value['@reverse'].each do |property, item|
                # If result does not have a property member, create one and set its value to an empty array.
                # Append item to the value of the property member of result.
                (output_object[property] ||= []).concat([item].flatten.compact)
              end
            end

            # If expanded value contains members other than @reverse:
            if !value.key?('@reverse') || value.length > 1
              # If result does not have an @reverse member, create one and set its value to an empty JSON object.
              reverse_map = output_object['@reverse'] ||= {}
              value.each do |property, items|
                next if property == '@reverse'
                items.each do |item|
                  if value?(item) || list?(item)
                    raise JsonLdError::InvalidReversePropertyValue,
                          item.inspect
                  end
                  merge_value(reverse_map, property, item)
                end
              end
            end

            # Continue with the next key from element
            next
          when '@default', '@embed', '@explicit', '@omitDefault', '@preserve', '@requireAll'
            next unless framing
            # Framing keywords
            [expand(value, expanded_property, context, ordered: ordered, framing: framing)].flatten
          when '@nest'
            # Add key to nests
            nests << key
            # Continue with the next key from element
            next
          else
            # Skip unknown keyword
            next
          end

          # Unless expanded value is null, set the expanded property member of result to expanded value.
          #log_debug("expand #{expanded_property}") { expanded_value.inspect}
          output_object[expanded_property] = expanded_value unless expanded_value.nil?
          next
        end

        # Use a term-specific context, if defined
        term_context = context.term_definitions[key].context if context.term_definitions[key]
        active_context = term_context ? context.parse(term_context) : context

        container = active_context.container(key)
        expanded_value = if active_context.coerce(key) == '@json'
          # In JSON-LD 1.1, values can be native JSON
          {"@value" => value, "@type" => "@json"}
        elsif container.length == 1 && container.first == '@language' && value.is_a?(Hash)
          # Otherwise, if key's container mapping in active context is @language and value is a JSON object then value is expanded from a language map as follows:
          
          # Set multilingual array to an empty array.
          ary = []

          # For each key-value pair language-language value in value, ordered lexicographically by language
          keys = ordered ? value.keys.sort : value.keys
          keys.each do |k|
            expanded_k = active_context.expand_iri(k, vocab: true, quiet: true).to_s
            [value[k]].flatten.each do |item|
              # item must be a string, otherwise an invalid language map value error has been detected and processing is aborted.
              raise JsonLdError::InvalidLanguageMapValue,
                    "Expected #{item.inspect} to be a string" unless item.nil? || item.is_a?(String)

              # Append a JSON object to expanded value that consists of two key-value pairs: (@value-item) and (@language-lowercased language).
              v = {'@value' => item}
              v['@language'] = k.downcase unless expanded_k == '@none'
              ary << v if item
            end
          end

          ary
        elsif container.any? { |key| CONTAINER_INDEX_ID_TYPE.include?(key) } && value.is_a?(Hash)
          # Otherwise, if key's container mapping in active context contains @index, @id, @type and value is a JSON object then value is expanded from an index map as follows:
          
          # Set ary to an empty array.
          ary = []

          # For each key-value in the object:
          keys = ordered ? value.keys.sort : value.keys
          keys.each do |k|
            # If container mapping in the active context includes @type, and k is a term in the active context having a local context, use that context when expanding values
            map_context = active_context.term_definitions[k].context if container.include?('@type') && active_context.term_definitions[k]
            map_context = active_context.parse(map_context) if map_context
            map_context ||= active_context

            expanded_k = active_context.expand_iri(k, vocab: true, quiet: true).to_s

            # Initialize index value to the result of using this algorithm recursively, passing active context, key as active property, and index value as element.
            index_value = expand([value[k]].flatten, key, map_context, ordered: ordered, framing: framing)
            index_value.each do |item|
              case container
              when CONTAINER_GRAPH_INDEX, CONTAINER_INDEX
                # Indexed graph by graph name
                if !graph?(item) && container.include?('@graph')
                  item = {'@graph' => as_array(item)}
                end
                item['@index'] ||= k unless expanded_k == '@none'
              when CONTAINER_GRAPH_ID, CONTAINER_ID
                # Indexed graph by graph name
                if !graph?(item) && container.include?('@graph')
                  item = {'@graph' => as_array(item)}
                end
                # Expand k document relative
                expanded_k = active_context.expand_iri(k, documentRelative: true, quiet: true).to_s unless expanded_k == '@none'
                item['@id'] ||= expanded_k unless expanded_k == '@none'
              when CONTAINER_TYPE
                item['@type'] = [expanded_k].concat(Array(item['@type'])) unless expanded_k == '@none'
              end

              # Append item to expanded value.
              ary << item
            end
          end
          ary
        else
          # Otherwise, initialize expanded value to the result of using this algorithm recursively, passing active context, key for active property, and value for element.
          expand(value, key, active_context, ordered: ordered, framing: framing)
        end

        # If expanded value is null, ignore key by continuing to the next key from element.
        if expanded_value.nil?
          #log_debug(" => skip nil value")
          next
        end
        #log_debug {" => #{expanded_value.inspect}"}

        # If the container mapping associated to key in active context is @list and expanded value is not already a list object, convert expanded value to a list object by first setting it to an array containing only expanded value if it is not already an array, and then by setting it to a JSON object containing the key-value pair @list-expanded value.
        if container.first == '@list' && container.length == 1 && !list?(expanded_value)
          #log_debug(" => ") { "convert #{expanded_value.inspect} to list"}
          expanded_value = {'@list' => as_array(expanded_value)}
        end
        #log_debug {" => #{expanded_value.inspect}"}

        # convert expanded value to @graph if container specifies it
        if container.first == '@graph' && container.length == 1
          #log_debug(" => ") { "convert #{expanded_value.inspect} to list"}
          expanded_value = as_array(expanded_value).map do |v|
            graph?(v) ? v : {'@graph' => as_array(v)}
          end
        end

        # Otherwise, if the term definition associated to key indicates that it is a reverse property
        # Spec FIXME: this is not an otherwise.
        if (td = context.term_definitions[key]) && td.reverse_property
          # If result has no @reverse member, create one and initialize its value to an empty JSON object.
          reverse_map = output_object['@reverse'] ||= {}
          [expanded_value].flatten.each do |item|
            # If item is a value object or list object, an invalid reverse property value has been detected and processing is aborted.
            raise JsonLdError::InvalidReversePropertyValue,
                  item.inspect if value?(item) || list?(item)

            # If reverse map has no expanded property member, create one and initialize its value to an empty array.
            # Append item to the value of the expanded property member of reverse map.
            merge_value(reverse_map, expanded_property, item)
          end
        else
          # Otherwise, if key is not a reverse property:
          # If result does not have an expanded property member, create one and initialize its value to an empty array.
          (output_object[expanded_property] ||= []).tap do |memo|
            # expanded_value is either Array[Hash] or Hash; in both case append to memo without flatten
            if expanded_value.is_a?(Array)
              memo.concat(expanded_value)
            else # Hash
              memo << expanded_value
            end
          end
        end
      end

      # For each key in nests, recusively expand content
      nests.each do |key|
        nested_values = as_array(input[key])
        nested_values.each do |nv|
          raise JsonLdError::InvalidNestValue, nv.inspect unless
            nv.is_a?(Hash) && nv.keys.none? {|k| context.expand_iri(k, vocab: true) == '@value'}
          expand_object(nv, active_property, context, output_object, ordered: ordered, framing: framing)
        end
      end
    end
  end
end
