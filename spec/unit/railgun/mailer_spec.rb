require 'json'
require 'logger'
require 'spec_helper'
require 'mailgun'
require 'railgun'

ActionMailer::Base.raise_delivery_errors = true
ActionMailer::Base.delivery_method = :test
Rails.logger = Logger.new('/dev/null')
Rails.logger.level = Logger::DEBUG

class UnitTestMailer < ActionMailer::Base
  default from: 'unittest@example.org'

  def plain_message(address, subject, headers)
    headers(headers)
    mail(to: address, subject: subject) do |format|
      format.text { render plain: "Test!" }
      format.html { render html: "<p>Test!</p>".html_safe }
    end
  end

  def template_message(address, subject, headers)
    headers(headers)
    mail(to: address, subject: subject, body: '').tap do |message|
      message.mailgun_template = 'template.test'
    end
  end
  
  def message_with_attachment(address, subject)
    attachments['info.txt'] = {
      :content => File.read('docs/railgun/Overview.md'),
      :mime_type => 'text/plain',
    }
    mail(to: address, subject: subject) do |format|
      format.text { render plain: "Test!" }
      format.html { render html: "<p>Test!</p>".html_safe }
    end
  end

end

describe 'Railgun::Mailer' do
  describe 'config' do
    before do
      @config =
        {
          api_key: 'default_blah',
          api_timeout: 60,
          domains: {
            'example.com' => {
              api_key: 'example.com_blah',
              api_version: 'v2'
            }
          }
        }
    end

    it 'has a mailgun_client property which returns a Mailgun::Client' do
      @mailer_obj = Railgun::Mailer.new(@config)

      expect(@mailer_obj.mailgun_client).to be_a(Mailgun::Client)
    end

    it 'must use the provided default configuration' do
      http_client = Railgun::Mailer.new(@config).mailgun_client.http_client

      expect(http_client.options[:user]).to eq('api')
      expect(http_client.options[:password]).to eq('default_blah')
      expect(http_client.url).to end_with('/v3')
    end

    it 'must use the provided domain specific configuration' do
      http_client = Railgun::Mailer.new(@config).mailgun_client('example.com').http_client
      
      expect(http_client.options[:user]).to eq('api')
      expect(http_client.options[:password]).to eq('example.com_blah')
      expect(http_client.url).to end_with('/v2')
    end
  end

  it 'properly creates a message body' do
    message = UnitTestMailer.plain_message('test@example.org', 'Test!', {})
    body = Railgun.transform_for_mailgun(message)

    [:from, :subject, :text, :html, 'to'].each do |param|
      expect(body).to include(param)
    end

    expect(body[:from][0].value).to eq('unittest@example.org')
    expect(body['to']).to eq(['test@example.org'])
    expect(body[:subject]).to eq(['Test!'])
    expect(body[:text]).to eq(['Test!'])
    expect(body[:html]).to eq(['<p>Test!</p>'.html_safe])
  end

  it 'adds options to message body' do
    message = UnitTestMailer.plain_message('test@example.org', '', {})
    message.mailgun_options ||= {
      'tracking-opens' => 'true',
    }

    body = Railgun.transform_for_mailgun(message)

    expect(body).to include('o:tracking-opens')
    expect(body['o:tracking-opens']).to eq('true')
  end

  it 'adds variables to message body' do
    message = UnitTestMailer.plain_message('test@example.org', '', {})

    mailgun_variables =  { 'user' => {:id => '1', :name => 'tstark'} }

    message.mailgun_variables ||= mailgun_variables
    
    body = Railgun.transform_for_mailgun(message)

    expect(body).to include('h:X-Mailgun-Variables')

    var_body = JSON.load(body['h:X-Mailgun-Variables'])
    expect(var_body['user']['id']).to eq('1')
    expect(var_body['user']['name']).to eq('tstark')
    expect(var_body).to eq(JSON.parse(JSON.dump(mailgun_variables)))
  end

  it 'adds headers to message body' do
    message = UnitTestMailer.plain_message('test@example.org', '', {})
    message.mailgun_headers ||= {
      'x-unit-test' => 'true',
    }

    body = Railgun.transform_for_mailgun(message)

    expect(body).to include('h:x-unit-test')
    expect(body['h:x-unit-test']).to eq('true')
  end

  it 'adds headers to message body from mailer' do
    message = UnitTestMailer.plain_message('test@example.org', '', {
      'x-unit-test-2' => 'true',
    })

    body = Railgun.transform_for_mailgun(message)

    expect(body).to include('h:x-unit-test-2')
    expect(body['h:x-unit-test-2']).to eq('true')
  end

  it 'adds template header to message body from mailer' do
    message = UnitTestMailer.template_message('test@example.org', '', {})

    body = Railgun.transform_for_mailgun(message)

    expect(body).to include('template')
    expect(body['template']).to eq('template.test')
  end
  
  it 'properly handles headers that are passed as separate POST params' do
    message = UnitTestMailer.plain_message('test@example.org', 'Test!', {
      # `From`, `To`, and `Subject` are set on the envelope, so they should be ignored as headers
      'From' => 'units@example.net',
      'To' => 'user@example.com',
      'Subject' => 'This should disappear',
      # If `Bcc` or `Cc` are set as headers, they should be carried over as POST params, not headers
      'Bcc' => ['list@example.org'],
      'Cc' => ['admin@example.com'],
      # This is an arbitrary header and should be carried over properly
      'X-Source' => 'unit tests',
    })

    body = Railgun.transform_for_mailgun(message)

    ['From', 'To', 'Subject'].each do |header|
      expect(body).not_to include("h:#{header}")
    end

    ['bcc', 'cc', 'to', 'h:x-source'].each do |param|
      expect(body).to include(param)
    end

    expect(body[:from][0].value).to eq('unittest@example.org')
    expect(body['to']).to eq(['test@example.org'])
    expect(body[:subject]).to eq(['Test!'])
    expect(body[:text]).to eq(['Test!'])
    expect(body[:html]).to eq(['<p>Test!</p>'.html_safe])
    expect(body['bcc']).to eq(['list@example.org'])
    expect(body['cc']).to eq(['admin@example.com'])
    expect(body['h:x-source']).to eq('unit tests')
  end

  it 'properly adds attachments' do
    message = UnitTestMailer.message_with_attachment('test@example.org', '')
    body = Railgun.transform_for_mailgun(message)

    expect(body).to include(:attachment)
    attachment = body[:attachment][0]

    expect(attachment.filename).to eq('info.txt')
    expect(attachment.content_type).to eq('text/plain')
  end

  it 'delivers!' do
    message = UnitTestMailer.plain_message('test@example.org', '', {})
    message.deliver_now

    expect(ActionMailer::Base.deliveries).to include(message)
  end

  it 'ignores `reply-to` in headers' do
    message = UnitTestMailer.plain_message('test@example.org', '', {
      'reply-to' => 'user@example.com',
    })
    message.mailgun_headers = {
      'Reply-To' => 'administrator@example.org',
    }
    message.headers({'REPLY-TO' => 'admin@example.net'})
    message.reply_to = "dude@example.com.au"

    body = Railgun.transform_for_mailgun(message)
    expect(body).to include('h:reply-to')
    expect(body).not_to include('h:Reply-To')
    expect(body['h:reply-to']).to eq('dude@example.com.au')
  end

  it 'treats `headers()` names as case-insensitve' do
    message = UnitTestMailer.plain_message('test@example.org', '', {
      'X-BIG-VALUE' => 1,
    })

    body = Railgun.transform_for_mailgun(message)
    expect(body).to include('h:x-big-value')
    expect(body['h:x-big-value']).to eq("1")
  end

  it 'treats `mailgun_headers` names as case-insensitive' do
    message = UnitTestMailer.plain_message('test@example.org', '', {})
    message.mailgun_headers = {
      'X-BIG-VALUE' => 1,
    }

    body = Railgun.transform_for_mailgun(message)
    expect(body).to include('h:x-big-value')
    expect(body['h:x-big-value']).to eq("1")
  end

  it 'handles multi-value, mixed case headers correctly' do
    message = UnitTestMailer.plain_message('test@example.org', '', {})
    message.headers({
      'x-neat-header' => 'foo',
      'X-Neat-Header' => 'bar',
      'X-NEAT-HEADER' => 'zoop',
    })

    body = Railgun.transform_for_mailgun(message)
    expect(body).to include('h:x-neat-header')
    expect(body['h:x-neat-header']).to include('foo')
    expect(body['h:x-neat-header']).to include('bar')
    expect(body['h:x-neat-header']).to include('zoop')
  end
end
