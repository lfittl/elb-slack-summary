#!/usr/bin/env ruby

require 'dotenv'
require 'aws-sdk'
require 'uri'
require 'slack-notifier'

Dotenv.load

s3 = Aws::S3::Client.new(
  access_key_id: ENV.fetch('AWS_ACCESS_KEY_ID'),
  secret_access_key: ENV.fetch('AWS_SECRET_ACCESS_KEY'),
  region: 'us-east-1',
)

Request = Struct.new(:timestamp, :elb, :client_ip_and_port, :backend_ip_and_port,
  :request_processing_time, :backend_processing_time, :response_processing_time,
  :elb_status_code, :backend_status_code, :received_bytes, :sent_bytes, :request,
  :user_agent, :ssl_cipher, :ssl_protocol) do
  def client_ip
    client_ip_and_port.split(':')[0]
  end

  def time
    Time.parse(timestamp)
  end

  def backend_processing_ms
    backend_processing_time.to_f * 1000
  end

  def request_method
    request.split(" ")[0]
  end

  def url
    request.split(" ")[1]
  end

  def hostname
    URI(url).host
  end

  def path
    URI(url).path
  end
end

requests = []

[Time.now.utc - 24 * 3_600, Time.now.utc].each do |ts|
  s3.list_objects_v2(
    bucket: ENV.fetch('S3_BUCKET'),
    delimiter: '/',
    prefix: ENV.fetch('S3_PATH') + ts.strftime('/%Y/%m/%d/'),
  ).contents.each do |obj|
    resp = s3.get_object(bucket: ENV.fetch('S3_BUCKET'), key: obj.key)

    resp.body.read.each_line do |line|
      r = Request.new(*line.strip.scan(/([^" ]+)|"([^"]+)"/).flatten.compact)

      next if r.user_agent == 'PINGOMETER_BOT_(HTTPS://PINGOMETER.COM)'
      next unless r.hostname == ENV.fetch('APP_HOSTNAME')
      next unless r.time > Time.now - 24 * 3_600

      requests << r
    end
  end
end

slowest_request_text = ""
requests.sort_by { |r| r.backend_processing_ms }.reverse[0,5].each do |r|
  slowest_request_text += format("%s %0.2fms %s\n", r.time.strftime("%H:%M:%S %Z"), r.backend_processing_ms, r.path)
end

slow_requests = requests.select { |r| r.backend_processing_ms > 500 }

slack = Slack::Notifier.new ENV.fetch('SLACK_WEBHOOK')
slack.ping("Load Balancer for #{ENV.fetch('APP_HOSTNAME')}: Backend performance in the last 24h", attachments: [
  {
    fields: [
      { title: "# Requests", value: requests.size, short: true },
      { title: "# Requests slower than 500ms", value: slow_requests.size, short: true },
      { title: "# Uniques", value: requests.map(&:client_ip).uniq.size, short: true },
      { title: "# Uniques with slow requests", value: slow_requests.map(&:client_ip).uniq.size, short: true },
      { title: "Top 5 Slowest Requests", value: slowest_request_text }
    ]
  }
])