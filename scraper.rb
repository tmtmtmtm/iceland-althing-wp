#!/bin/env ruby
# encoding: utf-8

require 'scraperwiki'
require 'nokogiri'
require 'date'
require 'open-uri'
require 'pry'

def noko(url)
  Nokogiri::HTML(open(url).read)
end

@parties = {
  'D' => 'Independence Party',
  'B' => 'Progressive Party',
  'S' => 'Social Democratic Alliance',
  'V' => 'Left-Green Movement',
  'A' => 'Bright Future',
  'P' => 'Pirate Party',
  'Þ' => 'Pirate Party',
  'C' => 'Reform Party',
}

def party_from(text)
  abbrev = @parties[ text[/\(([[:alpha:]]+)\)/,1] ] or raise "No party for #{$1}"
end

@WIKI = 'https://en.wikipedia.org'

def wikilink(a)
  return if a.attr('class') == 'new'
  a['title']
end

# -------
# Current
# -------
# https://en.wikipedia.org/wiki/List_of_members_of_the_parliament_of_Iceland
if current = noko('https://en.wikipedia.org/wiki/List_of_members_of_the_parliament_of_Iceland,_2013%E2%80%9316')
  table = current.xpath('//table[./caption[text()[contains(.,"Members")]]]')
  constituencies = table.xpath('tr[th]/th').map(&:text)

  count = 0
  table.xpath('tr[td]').first.xpath('td').each_with_index do |td, i|
    td.xpath('.//a').each do |p|
      data = {
        name: p.text.strip,
        wikipedia: wikilink(p),
        constituency: constituencies[i],
        party: party_from(p.xpath('./following-sibling::text()').first.text),
        term: '2013',
        start_date: nil,
        end_date: nil,
      }
      count += 1
      warn data
      ScraperWiki.save_sqlite([:name, :term], data)
    end
  end
  puts "Current: #{count}"

else
  raise "No current"
end

# --------
# Historic
# --------

@oldterms = {
  '1995' => "List_of_members_of_the_parliament_of_Iceland,_1995%E2%80%9399",
  '1999' => "List_of_members_of_the_parliament_of_Iceland,_1999%E2%80%932003",
  '2003' => "List_of_members_of_the_parliament_of_Iceland,_2003%E2%80%9307",
  '2007' => "List_of_members_of_the_parliament_of_Iceland,_2007%E2%80%9309",
  '2009' => "List_of_members_of_the_parliament_of_Iceland,_2009%E2%80%9313",
}

@oldterms.reverse_each do |term, pagename|
  url = "#{@WIKI}/wiki/#{pagename}"
  page = noko(url)
  count = 0

  # pre-load the Reference List
  notes = Hash[ page.css('.reflist .references li').map { |note|
    [ '#'+ note.css('@id').text, note ]
  }]

  # pre-load a Party Change table
  switches = Hash[
    page.xpath('//table[.//th[text()[contains(.,"New party")]]]/tr[td]').map { |row|
      tds = row.css('td')
      date = tds[1].text.strip
      date = Date.parse(tds[1].text).iso8601 if date.length > 4
      [
        tds[0].text.strip, {
          start_date: date,
          party: tds[3].text.split('[').first,
        }
      ]
    }
  ]

  # Find a table with a 'Constituency' column
  table = page.at_xpath('//table[.//th[text()[contains(.,"Constituency")]]]')
  table.xpath('tr[td]').each do |member|
    tds = member.xpath('td')
    data = {
      name: tds[0].css('a').first.text.strip,
      wikipedia: tds[0].xpath('a[not(@class="new")]/@title').text.strip,
      party: tds[1].xpath('a').text.strip,
      constituency: tds[2].text.gsub(/[[:space:]]/, ' ').strip,
      source: url,
      term: term,
      start_date: nil,
      end_date: nil,
    }

    # If we had a record in the "Changes" table:
    if switch = switches[data[:name]]
      replacement = data.merge(switch)
      data[:end_date] = switch[:start_date]
    end

    # If there are any reference notes on the Membership:
    if not (ref = tds[0].css('sup.reference a @href').text).empty?
      note = notes[ref].css('span.reference-text')

      # Replaced by someone else
      if replaced = note.children.each_slice(3).find { |t,_,_| t.text.include? 'Replaced by' }
        replacement = data.merge({
          name: replaced[1].text.strip,
          wikipedia: wikilink(replaced[1]),
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
          raise "Became what? #{notes[ref].text}"
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
        warn "odd note: #{notes[ref].text}"
      end
    end

    count += 1
    ScraperWiki.save_sqlite([:name, :term], data)
    (ScraperWiki.save_sqlite([:name, :term], replacement) && count+=1) if replacement
  end
  puts "#{term}: #{count}"
end

