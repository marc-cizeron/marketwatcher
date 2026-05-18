require 'faraday'
require 'faraday/retry'
require 'json'
require 'logger'
require_relative '../../config/settings'
require_relative 'web_search'
require_relative 'prompt_builder'

module Agent
  class Analyzer
    API_URL          = 'https://api.anthropic.com'.freeze
    MODEL            = 'claude-sonnet-4-6'.freeze
    MAX_TOKENS       = 4000
    INTER_CALL_DELAY = 65

    def initialize
      @logger = Logger.new($stdout)
      @client = build_client
    end

    def run(portfolio:, watchlist:, sectors: Settings::SECTORS)
      builder = PromptBuilder.new(portfolio: portfolio, watchlist: watchlist, sectors: sectors)

      @logger.info('Claude API — short-term analysis...')
      short_raw = call_api(builder.short_term_prompt)

      @logger.info("Waiting #{INTER_CALL_DELAY}s before second call (rate limit)...")
      sleep(INTER_CALL_DELAY)

      @logger.info('Claude API — long-term radar...')
      long_raw = call_api(builder.long_term_prompt)

      short = parse_json(short_raw)
      long  = parse_json(long_raw)

      {
        macro:                    short['macro'] || '',
        candidates:               short['candidates'] || [],
        recommendation:           short['recommendation'],
        recommendation_rationale: short['recommendation_rationale'],
        radar:                    long['radar'] || [],
        raw_short:                short_raw,
        raw_long:                 long_raw
      }
    end

    private

    def call_api(prompt, attempt: 1, max_attempts: 4)
      response = @client.post('/v1/messages') do |req|
        req.headers['Content-Type']      = 'application/json'
        req.headers['x-api-key']         = Settings::ANTHROPIC_API_KEY
        req.headers['anthropic-version'] = '2023-06-01'
        req.body = {
          model:      MODEL,
          max_tokens: MAX_TOKENS,
          tools:      [WebSearch::TOOL_DEFINITION],
          messages:   [{ role: 'user', content: prompt }]
        }.to_json
      end

      if response.status == 429
        raise "Rate limit exceeded after #{max_attempts} attempts" if attempt >= max_attempts
        wait = (response.headers['retry-after'] || 60).to_i + 5
        @logger.warn("429 rate limit — waiting #{wait}s (attempt #{attempt}/#{max_attempts})...")
        sleep(wait)
        return call_api(prompt, attempt: attempt + 1, max_attempts: max_attempts)
      end

      raise "API error #{response.status}: #{response.body}" unless response.success?

      body = JSON.parse(response.body)
      body['content']
        .select { |c| c['type'] == 'text' }
        .map    { |b| b['text'] }
        .join
    end

    def parse_json(raw)
      # 1. Try extracting from a ```json ... ``` fence
      if (m = raw.match(/```(?:json)?\s*\n?([\s\S]+?)\n?```/))
        return JSON.parse(m[1].strip)
      end
      # 2. Find first { or [ and parse from there
      if (m = raw.match(/(\{[\s\S]*\}|\[[\s\S]*\])/))
        return JSON.parse(m[1])
      end
      raise JSON::ParserError, 'no JSON found'
    rescue JSON::ParserError => e
      @logger.error("JSON parse error: #{e.message}\nRaw: #{raw[0..300]}")
      {}
    end

    def build_client
      Faraday.new(url: API_URL) do |f|
        f.request :retry,
                  max:            2,
                  interval:       5,
                  backoff_factor: 2,
                  exceptions:     [Faraday::TimeoutError, Faraday::ConnectionFailed]
        f.options.timeout      = 300
        f.options.open_timeout = 15
      end
    end
  end
end
