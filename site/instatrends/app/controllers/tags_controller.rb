require 'mongo'
require 'redis'
require 'uri'

MONGO_URL = "mongodb://heroku_app2168150:o6b2javvh03q2jn1mc3jjbjpdu@ds033067.mongolab.com:33067/heroku_app2168150"

class TagsController < ActionController::Base
	#Get info about a tag
	def view_tag
	    #Connect to mongo		
		uri = URI.parse(MONGO_URL)
		con = Mongo::Connection.from_uri(MONGO_URL)
		db = con.db(uri.path.gsub(/^\//, ''))
		col = db["Tags"]
		
		#Find tag
		@tag = col.find_one("name" => params["tag"])
		#If it doesnt exist, let them know
		unless @tag
			render	:text => "Either the tag doesn't exist or we can't track it" and return		
		end

		#Aggregate Tags
		col = db["Photos"]
		#Get latest 100 photos
		photos = col.find({"tag" => @tag["_id"]}, {:fields => "tags", :limit => 100}).to_a
		#Put each tag and count in a hash
		tags = Hash.new
		for p in photos
			for i in p["tags"]
				if tags.has_key? i
					tags[i] += 1
				else
					tags[i] = 1
				end
			end
		end
		#Sort tag counts - descending
		result = tags.sort_by { |k, v| v}
		@tag_stats = result.reverse

		#We only show top 20 tags
		@show = @tag_stats.length > 20 ? 20 : @tag_stats.length

		#Build Speed Chart
		@chart = get_chart(@tag["speed"])

		#Get locations for map
		@loc = col.find({"tag" => @tag["_id"], "location" => {"$ne" => nil}}).to_a
				
		respond_to do |format|
			format.html			
		end
	end
	
	#Handle user tags
	def tag
		#add tag
		if request.post?
			#Connect to redis
			redis_url = URI.parse('redis://redistogo:0a71fd9007797360bf43e845ca8cbf98@catfish.redistogo.com:9176/')
			redis = Redis.new(:host => redis_url.host, :port => redis_url.port, :password => redis_url.password)
			#get length of list, should be < 10 
			length = redis.scard("user tags")
			if length >= 10
				render :text => 'maxed' and return
			end

			#add new tag
			l = redis.sadd("user tags", params["tag"])
			#Publish add message 
			redis.publish("user", {"add" => params["tag"]}.to_json)
			render :text => 'done' and return
					
		#delete tag
		else request.delete?
			#Connect to redis
			redis_url = URI.parse('redis://redistogo:0a71fd9007797360bf43e845ca8cbf98@catfish.redistogo.com:9176/')
			redis = Redis.new(:host => redis_url.host, :port => redis_url.port, :password => redis_url.password)

			#Try to remove tag from set
			l = redis.srem("user tags", params["tag"])
			if l == 0
				render :text => 'does not exist' and return
			else
				#Publish delete message
				redis.publish("user", {"delete" => params["tag"]}.to_json )
				render :text => 'done' and return 
			end
		end
	end

	#Returns json of paginated photos specified by tag id
	def view_photos
		#Connect to mongo
		uri = URI.parse(MONGO_URL)
		con = Mongo::Connection.from_uri(MONGO_URL)
		db = con.db(uri.path.gsub(/^\//, ''))
		
		#Prepate tag id for query
		tag_id = BSON::ObjectId(params["tag"])
		col = db["Photos"]
		
		#Get most recent photos -> paginated
		@photos = col.find({"tag" => tag_id}, {:sort => ["created_time", -1], :limit => 51, :skip => 51*(params["page"].to_i-1)}).to_a

		respond_to do |format|
			format.json do render :json => @photos end
			end		
	end

	#View info about individual photo page
	def photo
		#Connect to db
		uri = URI.parse(MONGO_URL)
		con = Mongo::Connection.from_uri(MONGO_URL)
		db = con.db(uri.path.gsub(/^\//, ''))
		col = db["Photos"]

		#Find photo
		@photo = col.find_one("_id" => BSON::ObjectId(params["photo"]))

		respond_to do |format|
			format.html			
		end
	end

	#Build speed chart, return url
	def get_chart(data)
		y = ''
		#Google won't process any url larger than 2000, so we only use latest 500 speed data
		#Unreliable fix but doesn't break the site
		max = 500
		l = data.length
		return "" if l == 0
		show = l > max ? max : l-1
		#Find largest rate to properly scale data
		max_rate = 0
		for i in data[(-1*show)..(l-1)]
			if max_rate < i["rate"]
				max_rate = i["rate"]
			end					
			y += i["rate"].to_s + ','
		end

		#Add 50 to the scale to make it look nice
		chart_url_front = "http://chart.apis.google.com/chart?chxt=x%2Cy&chds=-5%2C#{max_rate + 50}&chs=500x160&cht=lc&chxr=1%2C-5%2C#{max_rate + 50}&chd=t:"
		chart_url_back = "&chco=orange&chl=New+media+per+minute"
		return chart_url_front + y[0..y.length-2] + chart_url_back
	end
end