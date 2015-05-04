
require 'scraperwiki'
require 'nokogiri'
require 'date'

require 'open-uri/cached'
require 'colorize'
require 'pry'

def noko(url)
  Nokogiri::HTML(open(url).read) 
end

@WIKI = 'http://en.wikipedia.org'
@terms = {
  '1995–1999' => "List_of_members_of_the_parliament_of_Iceland,_1995%E2%80%9399",
  '1999–2003' => "List_of_members_of_the_parliament_of_Iceland,_1999%E2%80%932003",
  '2003–2007' => "List_of_members_of_the_parliament_of_Iceland,_2003%E2%80%9307",
  '2007–2009' => "List_of_members_of_the_parliament_of_Iceland,_2007%E2%80%9309",
  '2009–2013' => "List_of_members_of_the_parliament_of_Iceland,_2009%E2%80%9313",
}

@terms.each do |term, pagename|
  url = "#{@WIKI}/wiki/#{pagename}"
  page = noko(url)

  # pre-load the Reference List
  notes = Hash[ page.css('.reflist .references li').map { |note|
    [ '#'+ note.css('@id').text, note ]
  }]

  # Find a table with a 'Constituency' column
  table = page.at_xpath('//table[.//th[text()[contains(.,"Constituency")]]]')
  table.xpath('tr[td]').each do |member|
    tds = member.xpath('td')
    data = { 
      name: tds[0].css('a').first.text.strip,
      wikipedia: tds[0].xpath('a[not(@class="new")]/@href').text.strip,
      party: tds[1].xpath('a').text.strip,
      constituency: tds[2].text.gsub(/[[:space:]]/, ' ').strip,
      source: url,
      term: term,
      start_date: nil,
      end_date: nil,
    }
    data[:wikipedia].prepend @WIKI unless data[:wikipedia].empty?

    # If no references, then we're done. Otherwise ...
    if not (ref = tds[0].css('sup.reference a @href').text).empty?
      note = notes[ref].css('span.reference-text')
      # puts "#{ref} = #{note}".magenta 

      # Replaced by someone else
      if replaced = note.children.each_slice(3).find { |t,_,_| t.text.include? 'Replaced by' }
        replacement = data.merge({ 
          name: replaced[1].text.strip,
          wikipedia: (replaced[1].attr('class') == 'new' ? '' : replaced[1]['href'])
        })

        if change_date = note.text[/on (\d+ \w+ \d+)/, 1]
          pdate = Date.parse(change_date) or raise "Can't parse #{pdate}"
          replacement[:start_date] = data[:end_date] = pdate.iso8601
        elsif change_year = note.text[/in (\d{4})/, 1]
          replacement[:start_date] = data[:end_date] = change_year
        else 
          raise "Can't parse dates in #{note}"
        end
        
      # Changed party
      elsif switch = note.children.each_slice(3).find { |t,_,_| t.text.include? 'Became' }
        if note.text.include? 'Became Prime Minister'
          # Ignore this for now
        elsif switch[0].text.include? 'Became independent'
          new_party = 'Independent'
          change_date_str = switch[0].text
        elsif switch[0].text.include? 'member of'
          new_party = switch[1].text
          change_date_str = switch[2].text
        else
          raise "Became what? #{notes[ref].text}".red
        end

        if new_party
          replacement = data.merge({ party: new_party })
          if change_year = change_date_str[/in (\d{4})/, 1]
            replacement[:start_date] = data[:end_date] = change_year
          else 
            raise "Can't parse dates in #{note}"
          end
        end
      else
        warn "odd note: #{notes[ref].text}".red
      end
    end

    require 'csv'
    puts data.values.to_csv
    # ScraperWiki.save_sqlite([:name], data)
    puts replacement.values.to_csv if replacement
    # ScraperWiki.save_sqlite([:name], replacement) if replacement
  end
end

__END__
