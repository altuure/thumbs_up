module ThumbsUp
  module ActsAsVoteable #:nodoc:

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def acts_as_voteable options={}
        has_many :votes, :as => :voteable, :dependent => :destroy

        include ThumbsUp::ActsAsVoteable::InstanceMethods
        extend  ThumbsUp::ActsAsVoteable::SingletonMethods
          if (options[:vote_sum_counter])
            unless Vote.respond_to?(:vote_sum_counter)
              Vote.send(:include,  ThumbsUp::ActsAsVoteable::VoteSumCounterClassMethods) 
              Vote.vote_sum_counters = [self]
            end
            
            
            vote_sum_counter_column = (options[:vote_sum_counter] == true) ? :vote_sum_counter : options[:vote_sum_counter]
            
                class_eval <<-EOS
                  def self.vote_sum_counter_column           # def self.vote_counter_column
                    :"#{vote_sum_counter_column}"            #   :vote_total
                  end                                    # end
                  def vote_sum_counter_column                
                    self.class.vote_sum_counter_column       
                  end                                    
                EOS
                
           define_method(:reload_vote_sum_counter) {reload(:select => vote_sum_counter_column.to_s)}
           attr_readonly vote_sum_counter_column
         end  

        if (options[:vote_counter])
          unless Vote.respond_to?(:vote_counter)
            Vote.send(:include,  ThumbsUp::ActsAsVoteable::VoteCounterClassMethods) 
            Vote.vote_counters = [self]
          end
            
            
            counter_column_name = (options[:vote_counter] == true) ? :vote_counter : options[:vote_counter]
            
                class_eval <<-EOS
                  def self.vote_counter_column           # def self.vote_counter_column
                    :"#{counter_column_name}"            #   :vote_total
                  end                                    # end
                  def vote_counter_column                
                    self.class.vote_counter_column       
                  end                                    
                EOS
                
           define_method(:reload_vote_counter) {reload(:select => vote_counter_column.to_s)}
           attr_readonly counter_column_name
         end                
                 
      end
    end


    module VoteSumCounterClassMethods
      def self.included(base)
        base.class_attribute(:vote_sum_counters)
        
        base.before_save { |record| record.update_vote_sum_counters(nil) }
        base.before_destroy { |record| record.update_vote_sum_counters(-1) }
      end

      def update_vote_sum_counters direction
        klass, vtbl = self.voteable.class, self.voteable
       
        v=0
        v_was=0
        if self.vote_changed? || (self.new_record? && self.vote==false )   
          v=(self.vote==true) ? 1 :-1;
        end
        if direction!=nil
            v_was=(self.vote_was==true) ? -1 :1
        end 
        v=v+v_was  
        
        if v!=0
          klass.update_counters(vtbl.id, vtbl.vote_sum_counter_column.to_sym => (v ) ) if self.vote_sum_counters.any?{|c| c == klass}
        end
      end
    end
    
    module VoteCounterClassMethods
      def self.included(base)
        base.class_attribute(:vote_counters)
        
        base.before_create { |record| record.update_vote_counters(+1) }
        base.before_destroy { |record| record.update_vote_counters(-1) }
      end

      def update_vote_counters direction
        klass, vtbl = self.voteable.class, self.voteable
        klass.update_counters(vtbl.id, vtbl.vote_counter_column.to_sym => (direction ) ) if self.vote_counters.any?{|c| c == klass}
        
      end
    end    
    
    module SingletonMethods
      
      # Calculate the plusminus for a group of voteables in one database query.
      # This returns an Arel relation, so you can add conditions as you like chained on to
      # this method call.
      # i.e. Posts.tally.where('votes.created_at > ?', 2.days.ago)
      def plusminus_tally
        t = self.joins("LEFT OUTER JOIN #{Vote.table_name} ON #{self.table_name}.id = #{Vote.table_name}.voteable_id")
        t = t.order("plusminus DESC")
        t = t.group("#{self.table_name}.id")
        t = t.select("#{self.table_name}.*")
        t = t.select("SUM(CASE CAST(#{Vote.table_name}.vote AS UNSIGNED) WHEN 1 THEN 1 WHEN 0 THEN -1 ELSE 0 END) AS plusminus")
        t = t.select("COUNT(#{Vote.table_name}.id) AS vote_count")
      end

      # #rank_tally is depreciated.
      alias_method :rank_tally, :plusminus_tally

      # Calculate the vote counts for all voteables of my type.
      # This method returns all voteables (even without any votes) by default.
      # The vote count for each voteable is available as #vote_count.
      # This returns an Arel relation, so you can add conditions as you like chained on to
      # this method call.
      # i.e. Posts.tally.where('votes.created_at > ?', 2.days.ago)
      def tally(*args)
        t = self.joins("LEFT OUTER JOIN #{Vote.table_name} ON #{self.table_name}.id = #{Vote.table_name}.voteable_id")
        t = t.order("vote_count DESC")
        t = t.group("#{self.table_name}.id")
        t = t.select("#{self.table_name}.*")
        t = t.select("COUNT(#{Vote.table_name}.id) AS vote_count")
      end

      def column_names_for_tally
        column_names.map { |column| "#{self.table_name}.#{column}" }.join(', ')
      end

    end

    module InstanceMethods

      def votes_for
        self.votes.where(:vote => true).count
      end

      def votes_against
        self.votes.where(:vote => false).count
      end

      def percent_for
        (votes_for.to_f * 100 / (self.votes.size + 0.0001)).round
      end

      def percent_against
        (votes_against.to_f * 100 / (self.votes.size + 0.0001)).round
      end

      # You'll probably want to use this method to display how 'good' a particular voteable
      # is, and/or sort based on it.
      def plusminus
        votes_for - votes_against
      end

      def votes_count
        self.votes.size
      end

      def voters_who_voted
        self.votes.map(&:voter).uniq
      end

      def voted_by?(voter)
        0 < Vote.where(
              :voteable_id => self.id,
              :voteable_type => self.class.base_class.name,
              :voter_id => voter.id
            ).count
      end
      
      def vote_sum
        list=self.votes.select('vote ,count(*) counts').group('vote')
        total=0
        list.each do |v|
          if v.vote
            total=v.counts+total            
          else
            total=total-v.counts
          end
        end
        total
      end

    end
  end
end
