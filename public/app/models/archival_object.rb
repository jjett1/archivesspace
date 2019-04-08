class ArchivalObject < Record
  include TreeNodes
  include ResourceRequestItems

  def parse_notes
    rewrite_refs(json['notes'], resource_uri) if resource_uri

    super
  end

  def resource_uri
    resolved_resource && resolved_resource['uri']
  end

  def direct_component_id
    if json.has_key?('component_id_inherited')
      ''
    else
      json.fetch('component_id', '')
    end
  end

  def instances
    json['instances']
  end

  def finding_aid
    # as this shares the same template as resources,
    # be clear that this object doesn't have a finding aid
    nil
  end

  def cite
    cite = note('prefercite')
    unless cite.blank?
      cite = strip_mixed_content(cite['note_text'])
    else
      cite = strip_mixed_content(display_string) + "."

      if resolved_resource
        ttl = resolved_resource.dig('title')

        cite += " #{strip_mixed_content(ttl)}"
        cite += "," unless cite.end_with?(',')
        cite += " #{identifier}"

        cite += "."
      end

      cite += " #{ repository_information['top']['name']}." unless !repository_information.dig('top','name')
    end

    "#{cite}   #{cite_url_and_timestamp}."
  end

  def root_node_uri
    json.fetch('resource').fetch('ref')
  end

  #should probably make these configurable options, but for now let's assume anything
  #like a "series" or greater is a Collection of some kind.
  #and Collections at the archival object level will be diffentiated from collections at the resource level
  #in ASpace by the fact that the archival objects will be "partOf" something else.
  def level_for_md_mapping
    if ['recordgrp', 'subgrp', 'fonds', 'collection', 'series'].include?(json['level'].downcase)
      ['Collection', 'ArchiveComponent']
    else
      'ArchiveComponent'
    end
  end

  def parent_for_md_mapping
    if json['parent'].try(:any?)
      json['parent']['ref']
    else
      json['resource']['ref']
    end
  end

  def metadata
    md = {
      '@context' => "http://schema.org/",
      '@type' => level_for_md_mapping,
      'name' => display_string,
      'url' => AppConfig[:public_proxy_url] + uri,
      'identifier' => json['identifier'],
      'isPartOf' => AppConfig[:public_proxy_url] + parent_for_md_mapping
    }.compact

    md['description'] = json['notes'].select{|n| n['type'] == 'abstract'}.map{|abstract|
                          strip_mixed_content(abstract['content'].join(' '))
                        }

    if md['description'].empty?
      md['description'] = json['notes'].select{|n| n['type'] == 'scopecontent'}.map{|scope|
                            strip_mixed_content(scope['subnotes'].map{|s| s['content']}.join(' '))
                          }
    end
    md['description'] = md['description'][0] if md['description'].length == 1


    md['creator'] = json['linked_agents'].select{|la| la['role'] == 'creator'}.map{|a| a['_resolved']}.map do |ag|
      {
        '@id' => AppConfig[:public_proxy_url] + ag['uri'],
        '@type' => ag['jsonmodel_type'] == 'agent_person' ? 'Person' : 'Organization',
        'name' => ag['title'],
        'sameAs' => ag['display_name']['authority_id']
      }.compact
    end

    #just mapping the whole (and direct) extents for now.
    md['materialExtent'] = json['extents'].select{|e| e['portion'] == 'whole'}
    .reject{|e| e['_inherited']}
    .map do |extent|
        {
          "@type": "QuantitativeValue",
          "unitText": I18n.t("enumerations.extent_extent_type.#{extent['extent_type']}"),
          "value": extent['number']
        }
    end

    term_type_to_about_type = {
      'geographic' => 'Place',
      'temporal' => 'TemporalCoverage',
      'uniform_title' => 'CreativeWork',
      'topical' => 'Intangible',
      'occupation' => 'Intangible'
    }

    md['about'] = json['subjects'].select{|s|
      term_type_to_about_type.keys.include?(s['_resolved']['terms'][0]['term_type'])
    }.map{|s| s['_resolved']}.map{|subj|
      hash = {'@type' => term_type_to_about_type[subj['terms'][0]['term_type']]}
      hash['@id'] = subj['authority_id'] if subj['authority_id']
      hash['name'] = subj['title']
      hash
    }

    md['about'].concat(json['linked_agents'].select{|la| la['role'] == 'subject'}.map{|a| a['_resolved']}.map{|ag|
                         {
                           '@type' => ag['jsonmodel_type'] == 'agent_person' ? 'Person' : 'Organization',
                           'name' => strip_mixed_content(ag['title']),
                         }
                       })

    md['genre'] = json['subjects'].select{|s|
      s['_resolved']['terms'][0]['term_type'] == 'genre_form'
    }.map{|s| s['_resolved']}.map{|subj|
      subj['authority_id'] ? subj['authority_id'] : subj['title']
    }

    #will need to update once more than one language code is allowed
    if raw['language'].try(:any?)
         md['inLanguage'] = {
           '@type' => 'Language',
           'name' => I18n.t("enumerations.language_iso639_2.#{raw['language']}", :default => raw['language'])
         }
    end

    #will need to update here (and elsewhere) once ASpace allows more than one authority ID.
    #at that point, move those over to "sameAs" relationships and move the URL value to @id.
    #also, are there any changes needed now that the PUI has the ability to override the database ids in the URIs?
    md['holdingArchive'] = {
      '@id' => json['repository']['_resolved']['agent_representation']['_resolved']['display_name']['authority_id'],
      'url' => AppConfig[:public_proxy_url] + raw['repository'],
      '@type' => 'ArchiveOrganization',
      'name' => json['repository']['_resolved']['name']
    }.compact

    md.delete_if { |key,value| value.empty? }
  end

end
