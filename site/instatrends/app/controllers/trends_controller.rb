require 'redis'

#init Redis 
Redis_url = URI.parse('redis://redistogo:0a71fd9007797360bf43e845ca8cbf98@catfish.redistogo.com:9176/')
$redis = Redis.new(:host => Redis_url.host, :port => Redis_url.port, :password => Redis_url.password)

class TrendsController < ActionController::Base
    #Main page
    def home
    	@tags = Array.new
    	last_update = Array.new

        #Get top 15 tags
        #We loop just in case we try to access the set after its been flushed
    	begin
    		@tags = $redis.zrevrange("popular", 0, 14)
    		last_update = $redis.get("last update")    		
    	end while not @tags
    	
    	#Get time 
    	t = Time.now.to_f
    	dif = t - last_update.to_f

        min =  dif > 60 ? dif/60 : 0        
        sec = min > 0 ? 60*(min - min.floor) : dif        

        #Build 'update time' string
    	@time = ''
    	@time << "#{min.floor} minutes, " unless min <= 0    		
    	@time << "#{sec.floor} seconds" unless sec.floor == 0

        #Get user specified tags
        @user_tags = $redis.smembers("user tags")
    	
    	respond_to do |format|
    		format.html
    		format.json do 
    			render :json => {"time" => @time, "data" => @tags}
    		end
    	end

    end
end


