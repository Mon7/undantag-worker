# encoding: utf-8

require 'amqp'
require 'mongo'
require 'github_api'
require 'erb'
require 'debugger'

def mongo
  @mongo ||= Mongo::Connection.new.db
end

def issues
  mongo['issues']
end

def bump_title_number(title)
  if number = title[/\[(?<digit>\d+)\]$/, :digit]
    title[/\[(?<digit>\d+)\]$/, :digit] = (number.to_i + 1).to_s
  else
    title
  end
end

def handle_exception(user, params)
  github = Github.new(oauth_token: user['oauth_token'])
  backtrace_hash = Digest::SHA1.hexdigest(params['backtrace'])

  github_id = user['id']
  backtrace = params['backtrace']
  github_user = params['github_user']
  github_repo = params['github_repo']
  if issue = issues.find_one('github_id' => github_id,
                             'backtrace_hash' => backtrace_hash,
                             'github_user' => github_user,
                             'github_repo' => github_repo)
  
    title = bump_title_number(issue['github_issue_title'])

    updated_issue = github.issues.edit(issue['github_user'], issue['github_repo'], issue['github_issue_number'], {
      title: title
    })

    issues.update({"_id" => issue["_id"]}, {"$set" => {
      'github_issue_title' => title       
    }})
  else
    new_issue = github.issues.create(github_user, github_repo, 
                                     title: "#{params['exception']} [1]", 
                                     body: ERB.new(File.read('views/issue.markdown.erb')).result(binding))

    issues.insert({
      'github_id' => github_id,
      'backtrace_hash' => backtrace_hash,
      'github_user' => github_user,
      'github_repo' => github_repo,
      'github_issue_number' => new_issue.number,
      'github_issue_title' => new_issue.title
    })
  end
end

EM.run do
  amqp_connection = AMQP.connect(ENV['CLOUDAMQP_URL'])
  channel = AMQP::Channel.new(amqp_connection)
  github_exchange = channel.topic('github')
  queue = channel.queue('', auto_delete: true).bind(github_exchange, key: 'request')

  queue.subscribe do |header, data|
    data_hash = BSON.deserialize(data)
    user = data_hash['user']
    params = data_hash['params']
    handle_exception(user, params)
  end
end


