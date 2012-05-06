# Finds top popular tags and puts them into a redis sorted-set

require 'json'
require 'open-uri'
require 'uri'
require 'redis'

#Redis 
Redis_url = URI.parse('redis://redistogo:0a71fd9007797360bf43e845ca8cbf98@catfish.redistogo.com:9176/')
$redis = Redis.new(:host => Redis_url.host, :port => Redis_url.port, :password => Redis_url.password)

#Instagram
ClientID = 'ac07a2715b874192ac89818b329f350a'
Base_url = 'https://api.instagram.com/v1'
#GET /media/popular
endpoint = '/media/popular?client_id='

#Seconds to wait after each api call
Delay = 60  #60
#Number of iterations before saving tags to db
Iterations = 10  #10

#Store ids of photos we have already seen
old_ids = Hash.new
tags = Hash.new

#Sort tags by their count is descending order
def sort_tags(tags)
	sorted = tags.sort_by { |tag, count| count }
	return sorted.reverse
end

#Main loop
loop do
	tags.clear
	old_ids.clear
	error = false
	for time in 1..Iterations
		#In case of error, restart count (we dont know how long we slept becouse of the error)
		break if error	
		url = Base_url + endpoint + ClientID
		begin 
			data = JSON.parse(open(url).read)
		#In case of an error, we can't shut this script down, so sleep and keep trying
		rescue Exception => e
			print "ERROR: #{e.message}\n"
			sleep(100)
			error = true
			break
		end
		
		unless data["meta"]["code"] == 200
			print "error\n"
			sleep(100)
			error = true
			break
		end

		#Process photos
		for i in data["data"]
			#Filter old elements by checking if id appeared before
			next if old_ids.has_key? i["id"]
			#Add id to hash
			old_ids[i["id"]] = nil

			#Aggregate tags
			for tag in i["tags"]
				if tags.has_key? tag
					tags[tag] += 1
				else
					tags[tag] = 1
				end

			end
		end		
		sleep(Delay)			
	end
	
	#sort tags
	sorted = sort_tags tags
	#We store only top 20 tags or less
	limit = ((l = sorted.length) > 20) ? 20 : l	
	
	#Update sorted-set
	$redis.multi do
		#Fulsh set
		$redis.del "popular"	
		for i in sorted[0..limit]
			#filter out all tags with count == 1
			break if i[1] == 1
			$redis.zadd("popular", i[1], i[0])		
		end
		
		$redis.set("last update", Time.now.to_i)
		$redis.publish("popular", "new")
	end	
end
