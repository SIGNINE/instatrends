# Track individual tags from popular sorted-set

require 'redis'
require 'mongo'
require 'uri'
require 'open-uri'
require 'json'

Redis_url = URI.parse('redis://redistogo:0a71fd9007797360bf43e845ca8cbf98@catfish.redistogo.com:9176/')
Mongo_url = "mongodb://heroku_app2168150:o6b2javvh03q2jn1mc3jjbjpdu@ds033067.mongolab.com:33067/heroku_app2168150"
 
#Instagram
ClientID = 'ac07a2715b874192ac89818b329f350a'
Base_url = 'https://api.instagram.com/v1'

redis_listener = Redis.new(:host => Redis_url.host, :port => Redis_url.port, :password => Redis_url.password)
$redis = Redis.new(:host => Redis_url.host, :port => Redis_url.port, :password => Redis_url.password)

Tracker_delay = 60

#Make instagram api call
def insta_request(type, tag = '', count = 0)
    #Build url
    url = ''
    if type == :popular
        url =  Base_url + "/media/popular?client_id=" + ClientID
    elsif type == :recent
        url = Base_url + "/tags/#{tag}/media/recent?count=#{count}&client_id=" + ClientID
    else
        url = Base_url + "/tags/#{tag}?client_id=" + ClientID
    end
    #Send request and return json response
    begin
        return JSON.parse(open(url).read)
    rescue Exception => e
        #For all errors except for 502, kill thread, remove tag from redis set and tags hash
        unless e.message.include? '502'
            puts tag           
            puts e.message
            
            #We are sharing redis clients between all threads
            mutex = Mutex.new
            mutex.synchronize do
                $redis.zrem("popular", tag)
            end
            #Never call this function in main thread
            exit
        #if 502, sleep and retry
        else
            puts e.message
            sleep(100)
            return insta_request(type, tag, count)
        end
    end
end


def tracker(tag)
    #Connect with mongo and get col
    con = Mongo::Connection.from_uri(Mongo_url)
    db = con.db(URI.parse(Mongo_url).path.gsub(/^\//, ''))
    col_tags = db['Tags']
    #Try to find the tag we want in db
    tag_id = col_tags.find_one("name" => tag)
    unless tag_id
        #If it doesn't exist, make a new doc for the tag
        new_tag = 
        {
            "name" => tag,            
            "speed" => []
        }
        tag_id = col_tags.insert(new_tag)
    else
        tag_id = tag_id["_id"]
    end 
    
    col_photos = db["Photos"] 
    
    #Filtering algorithm --> to prevent inserting photos that already exist in db
    #Get most recent 20 photos from db and put each photo id in a hash ( O(1) look up )
    #Check if each new photo exists in the hash before inserting in db
    #Add new photo ids to hash 
    recent_photos = Hash.new
    last20 = col_photos.find({"tag" => tag_id}, {:limit => 20, :sort => ["created_time", -1]}).each do |p|
        recent_photos[p["id"]] = nil 
    end    

    #Get media count to calculate speed 
    resp = insta_request(:speed, tag = tag)
    exit unless resp["meta"]["code"] == 200
    old_media_count = resp["data"]["media_count"]
    first_time = true

    #Tracking loop
    loop do
        #In 1st iteration, no point in geting media count right away again so sleep     
        if first_time
            first_time = false
            sleep(Tracker_delay)
            next
        end

        #Get media count
        resp = insta_request(:speed, tag = tag)         

        exit if resp["meta"]["code"] != 200
        
        new_media_count = resp["data"]["media_count"]
        #calculate speed
        speed = new_media_count - old_media_count 
        old_media_count = new_media_count
        
        if speed > 0
           #Get recent photos
           #To help with filtering, only get photos that are new
           resp = insta_request(:recent, tag, speed)
                
           exit if resp["meta"]["code"] != 200

           for photo in resp["data"]
               #Check if photo id is in hash               
               if recent_photos.has_key? photo["id"]
                    next
               end
               #build photo JSON
               new_photo = 
                {
                    "tag" => tag_id,
                    "id" => photo["id"],
                    "created_time" => photo["created_time"],
                    "caption" => photo["caption"] ? photo["caption"]["text"] : nil,
                    "tags" => photo["tags"],
                    "link" => photo["link"] ? photo["link"].gsub(/\\/, '') : nil,
                    "img_large" => photo["images"]["standard_resolution"]["url"].gsub(/\\/, ''),
                    "img_small" => photo["images"]["thumbnail"]["url"].gsub(/\\/, ''),  
                    "location" => photo["location"] ? [photo["location"]["latitude"], photo["location"]["longitude"]] : nil      
                }

                #Insert in db and update hash (is there bulk insert?)
                col_photos.insert(new_photo)
                recent_photos[photo["id"]] = nil    
           end
        end
        
        #Build speed json
        new_speed =
        {
            "rate" => speed,
            "time" => Time.now.to_i
        }  
        col_tags.update({"_id" => tag_id}, {"$push" => {"speed" => new_speed}} , {:safe => true})

        #The end, time to sleep
        sleep(Tracker_delay)
    end
end
#---------------------------------------- MAIN ------------------------------------------------------


$tags = Hash.new
redis_listener.subscribe("popular") do |on|
	on.message do |channel, msg|        
		new_tags = $redis.zrevrange("popular", 0, 14)
		puts msg
		#This is a horrible way to filter new tags and get rid of
		
		for t in $tags.keys
			#if tag is no longer popular, shut down tracker
			unless new_tags.include? t
                begin
                     Thread.kill($tags[t])               
                rescue Exception => e
                end				
				
                $tags.delete t
				print "Deleting thread #{t}\n"	
			end					
		end
		
		for t in new_tags			
            unless $tags.has_key? t
                puts "Creating thread #{t}\n"
                $tags[t] = Thread.new(t) { |t|
                    begin
                        tracker(t)
		    rescue Exception => e
		        print "\n#{t}  #{e.message}\n"
                        print e.backtrace.join("\n")					
		        end
		    } 	
            end	
    end
      	
end
