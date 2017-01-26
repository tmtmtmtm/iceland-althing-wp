#!/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

require 'date'
require 'nokogiri'
require 'open-uri'
require 'pry'
require 'scraped'
require 'scraperwiki'

def noko(url)
  Nokogiri::HTML(open(url).read)
end

def scrape(h)
  url, klass = h.to_a.first
  klass.new(response: Scraped::Request.new(url: url).response)
end

class Party
  PARTIES = {
    'D' => 'Independence Party',
    'B' => 'Progressive Party',
    'S' => 'Social Democratic Alliance',
    'V' => 'Left-Green Movement',
    'A' => 'Bright Future',
    'P' => 'Pirate Party',
    'Þ' => 'Pirate Party',
    'C' => 'Reform Party',
  }.freeze

  def initialize(id)
    @id = id
  end

  def name
    PARTIES[id[/\(([[:alpha:]]+)\)/, 1]] or raise "No party for #{Regexp.last_match(1)}"
  end

  private

  attr_reader :id
end

@WIKI = 'https://en.wikipedia.org'

# TODO: move this into a shared base class
def wikilink(a)
  return if a.attr('class') == 'new'
  a['title']
end

class MembersPageWithAreaTable < Scraped::HTML
  field :members do
    table.xpath('tr[td]').first.xpath('td').each_with_index.map do |td, i|
      td.xpath('.//a').map do |p|
        {
          name:         p.text.strip,
          wikipedia:    wikilink(p),
          constituency: constituencies[i],
          party:        Party.new(p.xpath('./following-sibling::text()').first.text).name,
          term:         nil, # splice in later
          start_date:   nil,
          end_date:     nil,
        }
      end
    end.flatten
  end

  private

  def table
    noko.xpath('//table[./caption[text()[contains(.,"Members")]]]')
  end

  def constituencies
    @cons ||= table.xpath('tr[th]/th').map(&:text)
  end
end

# Clean out old data and start fresh each time
ScraperWiki.sqliteexecute('DELETE FROM data') rescue nil

# ----------
# New layout
# ----------

new_terms = {
  '2016' => 'https://en.wikipedia.org/wiki/Template:MembersAlthing2016',
  '2013' => 'https://en.wikipedia.org/wiki/Template:MembersAlthing2013',
}

old_revisions = {
  '2013' => 'https://en.wikipedia.org/w/index.php?title=Template:MembersAlthing2013&direction=prev&oldid=714280236',
}

def scrape_new_format_terms(*term_hashes)
  term_hashes.each do |term_hash|
    term_hash.each do |term, url|
      members = (scrape url => MembersPageWithAreaTable).members.each do |m|
        ScraperWiki.save_sqlite(%i(name term), m.merge(term: term))
      end
      puts "#{term}: #{members.count}"
    end
  end
end

scrape_new_format_terms(new_terms, old_revisions)

# ----------
# Old layout
# ----------
# TODO: move these to Scraped

@oldterms = {
  '1995' => 'List_of_members_of_the_parliament_of_Iceland,_1995%E2%80%9399',
  '1999' => 'List_of_members_of_the_parliament_of_Iceland,_1999%E2%80%932003',
  '2003' => 'List_of_members_of_the_parliament_of_Iceland,_2003%E2%80%9307',
  '2007' => 'List_of_members_of_the_parliament_of_Iceland,_2007%E2%80%9309',
  '2009' => 'List_of_members_of_the_parliament_of_Iceland,_2009%E2%80%9313',
}

@oldterms.reverse_each do |term, pagename|
  url = "#{@WIKI}/wiki/#{pagename}"
  page = noko(url)
  count = 0

  # pre-load the Reference List
  notes = Hash[page.css('.reflist .references li').map do |note|
    ['#' + note.css('@id').text, note]
  end]

  # pre-load a Party Change table
  switches = Hash[
    page.xpath('//table[.//th[text()[contains(.,"New party")]]]/tr[td]').map do |row|
      tds = row.css('td')
      date = tds[1].text.strip
      date = Date.parse(tds[1].text).iso8601 if date.length > 4
      [
        tds[0].text.strip, {
          start_date: date,
          party:      tds[3].text.split('[').first,
        },
      ]
    end
  ]

  # Find a table with a 'Constituency' column
  table = page.at_xpath('//table[.//th[text()[contains(.,"Constituency")]]]')
  table.xpath('tr[td]').each do |member|
    tds = member.xpath('td')
    data = {
      name:         tds[0].css('a').first.text.strip,
      wikipedia:    tds[0].xpath('a[not(@class="new")]/@title').text.strip,
      party:        tds[1].xpath('a').text.strip,
      constituency: tds[2].text.gsub(/[[:space:]]/, ' ').strip,
      source:       url,
      term:         term,
      start_date:   nil,
      end_date:     nil,
    }

    # If we had a record in the "Changes" table:
    if switch = switches[data[:name]]
      replacement = data.merge(switch)
      data[:end_date] = switch[:start_date]
    end

    # If there are any reference notes on the Membership:
    unless (ref = tds[0].css('sup.reference a @href').text).empty?
      note = notes[ref].css('span.reference-text')

      # Replaced by someone else
      if replaced = note.children.each_slice(3).find { |t, _, _| t.text.include? 'Replaced by' }
        replacement = data.merge(name:      replaced[1].text.strip,
                                 wikipedia: wikilink(replaced[1]))

        if change_date = note.text[/on (\d+ \w+ \d+)/, 1]
          pdate = Date.parse(change_date) or raise "Can't parse #{pdate}"
          replacement[:start_date] = data[:end_date] = pdate.iso8601
        elsif change_year = note.text[/in (\d{4})/, 1]
          replacement[:start_date] = data[:end_date] = change_year
        else
          raise "Can't parse dates in #{note}"
        end

      # Changed party
      elsif switch = note.children.each_slice(3).find { |t, _, _| t.text.include? 'Became' }
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
          replacement = data.merge(party: new_party)
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
    ScraperWiki.save_sqlite(%i(name term), data)
    (ScraperWiki.save_sqlite(%i(name term), replacement) && count += 1) if replacement
  end
  puts "#{term}: #{count}"
end
