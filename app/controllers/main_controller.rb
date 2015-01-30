# coding: utf-8
class MainController < ApplicationController

  before_filter :authenticate, :except => [:index, :login]
  before_filter :check_viewability, :except => [:index, :login]

  append_before_filter :confirm_and_update_start_time, 
                       :except => [:index, 
                                   :login, 
                                   :confirm_contest_start]

  # to prevent log in box to be shown when user logged out of the
  # system only in some tab
  prepend_before_filter :reject_announcement_refresh_when_logged_out, 
                        :only => [:announcements]

  # COMMENTED OUT: filter in each action instead
  # before_filter :verify_time_limit, :only => [:submit]

  verify :method => :post, :only => [:submit],
         :redirect_to => { :action => :index }

  # COMMENT OUT: only need when having high load
  # caches_action :index, :login

  # NOTE: This method is not actually needed, 'config/routes.rb' has
  # assigned action login as a default action.
  def index
    redirect_to :action => 'login'
  end

  def login
    saved_notice = flash[:notice]
    reset_session
    flash.now[:notice] = saved_notice

    # EXPERIMENT:
    # Hide login if in single user mode and the url does not
    # explicitly specify /login
    #
    # logger.info "PATH: #{request.path}"
    # if GraderConfiguration['system.single_user_mode'] and 
    #     request.path!='/main/login'
    #   @hidelogin = true
    # end

    @announcements = Announcement.find_for_frontpage
    render :action => 'login', :layout => 'empty'
  end

  def list
    if session[:current_problem_id]
      @current_problem = Problem.find(session[:current_problem_id])
      session[:current_problem_id] = nil
    end
    prepare_list_information
  end

  def help
    @user = User.find(session[:user_id])
  end

  def submit
    user = User.find(session[:user_id])

    @submission = Submission.new
    @current_problem = Problem.find(params[:submission][:problem_id])

    if !@current_problem
      flash[:notice] = 'Error: คุณยังไม่ได้ระบุข้อที่ต้องการส่ง'
      redirect_to :action => 'list'
    end

    assignment = user.get_test_pair_assignment_for(@current_problem)
    if !assignment
      flash[:notice] = 'Error: คุณยังไม่ได้ดาวน์โหลดข้อมูลทดสอบ'
      prepare_list_information
      render :action => 'list' and return
    end
    if assignment.expired?
      flash[:notice] = 'Error: หมดเวลาส่งสำหรับข้อนี้'
      prepare_list_information
      render :action => 'list' and return
    end
    
    @submission.problem = @current_problem
    @submission.user = user
    @submission.language_id = 0
    if (params['file']) and (params['file']!='')
      @submission.source = params['file'].read 
      @submission.source_filename = params['file'].original_filename
    end
    if (params['output_file']) and (params['output_file']!='')
      @submission.output = params['output_file'].read 
    end
    @submission.submitted_at = Time.new.gmtime

    if GraderConfiguration.time_limit_mode? and user.contest_finished?
      @submission.errors.add(:base,"The contest is over.")
      prepare_list_information
      render :action => 'list' and return
    end

    if @submission.valid?
      if @submission.save == false
	flash[:notice] = 'Error saving your submission'
      elsif Task.create(:submission_id => @submission.id, 
                        :status => Task::STATUS_INQUEUE) == false
	flash[:notice] = 'Error adding your submission to task queue'
      else
        flash[:notice] = 'จัดเก็บคำตอบและโปรแกรมที่คุณส่งเรียบร้อย'
      end
    else
      prepare_list_information
      render :action => 'list' and return
    end

    if @current_problem
      session[:current_problem_id] = @current_problem.id
    end
    redirect_to :action => 'list'
  end

  def source
    submission = Submission.find(params[:id])
    if ((submission.user_id == session[:user_id]) and 
        (submission.problem != nil) and 
        (submission.problem.available))
      send_data(submission.source, 
		{:filename => submission.download_filename, 
                  :type => 'text/plain'})
    else
      flash[:notice] = 'Error viewing source'
      redirect_to :action => 'list'
    end
  end

  def compiler_msg
    @submission = Submission.find(params[:id])
    if @submission.user_id == session[:user_id]
      render :action => 'compiler_msg', :layout => 'empty'
    else
      flash[:notice] = 'Error viewing source'
      redirect_to :action => 'list'
    end
  end

  def submission
    @user = User.find(session[:user_id])
    @problems = @user.available_problems
    if params[:id]==nil
      @problem = nil
      @submissions = nil
    else
      @problem = Problem.find_by_name(params[:id])
      if not @problem.available
        redirect_to :action => 'list'
        flash[:notice] = 'Error: submissions for that problem are not viewable.'
        return
      end
      @submissions = Submission.find_all_by_user_problem(@user.id, @problem.id)
    end
  end

  def result
    if !GraderConfiguration.show_grading_result
      redirect_to :action => 'list' and return
    end
    @user = User.find(session[:user_id])
    @submission = Submission.find(params[:id])
    if @submission.user!=@user
      flash[:notice] = 'You are not allowed to view result of other users.'
      redirect_to :action => 'list' and return
    end
    prepare_grading_result(@submission)
  end

  def load_output
    if !GraderConfiguration.show_grading_result or params[:num]==nil
      redirect_to :action => 'list' and return
    end
    @user = User.find(session[:user_id])
    @submission = Submission.find(params[:id])
    if @submission.user!=@user
      flash[:notice] = 'You are not allowed to view result of other users.'
      redirect_to :action => 'list' and return
    end
    case_num = params[:num].to_i
    out_filename = output_filename(@user.login, 
                                   @submission.problem.name,
                                   @submission.id,
                                   case_num)
    if !FileTest.exists?(out_filename)
      flash[:notice] = 'Output not found.'
      redirect_to :action => 'list' and return
    end

    if defined?(USE_APACHE_XSENDFILE) and USE_APACHE_XSENDFILE
      response.headers['Content-Type'] = "application/force-download"
      response.headers['Content-Disposition'] = "attachment; filename=\"output-#{case_num}.txt\""
      response.headers["X-Sendfile"] = out_filename
      response.headers['Content-length'] = File.size(out_filename)
      render :nothing => true
    else
      send_file out_filename, :stream => false, :filename => "output-#{case_num}.txt", :type => "text/plain"
    end
  end

  def error
    @user = User.find(session[:user_id])
  end

  # announcement refreshing and hiding methods

  def announcements
    if params.has_key? 'recent'
      prepare_announcements(params[:recent])
    else
      prepare_announcements
    end
    render(:partial => 'announcement', 
           :collection => @announcements,
           :locals => {:announcement_effect => true})
  end

  def confirm_contest_start
    user = User.find(session[:user_id])
    if request.method == 'POST'
      user.update_start_time
      redirect_to :action => 'list'
    else
      @contests = user.contests
      @user = user
    end
  end

  # thailandoi contests

  def verifying_testcase
    problem = Problem.find(params[:id])
    if !problem.available
      flash[:notice] = 'Error: problem is not available'
      redirect_to :action => 'list'
    else
      test_pair = TestPair.get_for(problem, false)
      send_data(test_pair.input, 
		{:filename => problem.name + '-verifying-input.txt', 
                 :type => 'text/plain'})      
    end
  end
  
  def testcase
    problem = Problem.find(params[:id])
    if !problem.available
      flash[:notice] = 'Error: problem is not available'
      redirect_to :action => 'list'
    else
      test_pair = TestPair.get_for(problem, true)

      user = User.find(session[:user_id])
      assignment = user.get_test_pair_assignment_for(problem)

      if !assignment
        assignment = TestPairAssignment.create_for(user, problem, test_pair)
        assignment.save
      end

      send_data(test_pair.input, 
		{:filename => problem.name + '-input.txt', 
                 :type => 'text/plain'})      
    end
  end
  
  def verifying_submit
    user = User.find(session[:user_id])
    problem_id = params[:id]
    problem = Problem.find(problem_id)

    if !problem or !problem.available
      flash[:notice] = 'Error: problem is not available'
      redirect_to :action => 'list' and return
    end
     
    @current_problem = problem
    test_pair = TestPair.get_for(problem, false)
    if (params['output_file']) and (params['output_file']!='')
      output = params['output_file'].read   

      @grading_result = grade(output, test_pair.solution)
      prepare_list_information
      render :action => 'list' and return
    else
      flash[:notice] = 'Error: output file errors'
      prepare_list_information
      render :action => 'list' and return
    end
  end

  protected

  def grade(output, solution)
    out_items = output.split("\n")
    sol_items = solution.split("\n")
    res = ''
    f = 0
    s = 0
    sol_items.length.times do |i|
      f += 1
      si = sol_items[i].chomp
      if out_items[i]
        oi = out_items[i].chomp
      else
        oi = ''
      end
      if oi == si
        res = res + 'P'
        s += 1
      else
        res = res + '-'
      end
    end
    return { :score => s, :full_score => f, :msg => res }
  end
  
  def prepare_announcements(recent=nil)
    if GraderConfiguration.show_tasks_to?(@user)
      @announcements = Announcement.find_published(true)
    else
      @announcements = Announcement.find_published
    end
    if recent!=nil
      recent_id = recent.to_i
      @announcements = @announcements.find_all { |a| a.id > recent_id }
    end
  end

  def prepare_timeout_information(problems)
    @submission_timeouts = {}
    problems.each do |problem|
      assignment = @user.get_test_pair_assignment_for(problem)
      if assignment == nil
        timeout = nil
      else
        if (assignment.expired?) or (assignment.submitted)
          timeout = 0
        else
          timeout = assignment.created_at + TEST_ASSIGNMENT_EXPIRATION_DURATION - Time.new.gmtime
        end
      end
      @submission_timeouts[problem.id] = timeout
    end
  end
  
  def prepare_list_information
    @user = User.find(session[:user_id])
    if not GraderConfiguration.multicontests?
      @problems = @user.available_problems
    else
      @contest_problems = @user.available_problems_group_by_contests
      @problems = @user.available_problems
    end
    @prob_submissions = {}
    @problems.each do |p|
      sub = Submission.find_last_by_user_and_problem(@user.id,p.id)
      if sub!=nil
        @prob_submissions[p.id] = { :count => sub.number, :submission => sub }
      else
        @prob_submissions[p.id] = { :count => 0, :submission => nil }
      end
    end
    prepare_announcements
    prepare_timeout_information(@problems)
  end

  def check_viewability
    @user = User.find(session[:user_id])
    if (!GraderConfiguration.show_tasks_to?(@user)) and
        ((action_name=='submission') or (action_name=='submit'))
      redirect_to :action => 'list' and return
    end
  end

  def prepare_grading_result(submission)
    if GraderConfiguration.task_grading_info.has_key? submission.problem.name
      grading_info = GraderConfiguration.task_grading_info[submission.problem.name]
    else
      # guess task info from problem.full_score
      cases = submission.problem.full_score / 10
      grading_info = {
        'testruns' => cases, 
        'testcases' => cases
      }
    end
    @test_runs = []
    if grading_info['testruns'].is_a? Integer
      trun_count = grading_info['testruns']
      trun_count.times do |i|
        @test_runs << [ read_grading_result(@user.login,
                                            submission.problem.name,
                                            submission.id,
                                            i+1) ]
      end
    else
      grading_info['testruns'].keys.sort.each do |num|
        run = []
        testrun = grading_info['testruns'][num]
        testrun.each do |c|
          run << read_grading_result(@user.login,
                                     submission.problem.name,
                                     submission.id,
                                     c)
        end
        @test_runs << run
      end
    end
  end

  def grading_result_dir(user_name, problem_name, submission_id, case_num)
    return "#{GRADING_RESULT_DIR}/#{user_name}/#{problem_name}/#{submission_id}/test-result/#{case_num}"
  end
  
  def output_filename(user_name, problem_name, submission_id, case_num)
    dir = grading_result_dir(user_name,problem_name, submission_id, case_num)
    return "#{dir}/output.txt"
  end

  def read_grading_result(user_name, problem_name, submission_id, case_num)
    dir = grading_result_dir(user_name,problem_name, submission_id, case_num)
    result_file_name = "#{dir}/result"
    if !FileTest.exists?(result_file_name)
      return {:num => case_num, :msg => 'program did not run'}
    else
      results = File.open(result_file_name).readlines
      run_stat = extract_running_stat(results)
      output_filename = "#{dir}/output.txt"
      if FileTest.exists?(output_filename)
        output_file = true
        output_size = File.size(output_filename)
      else
        output_file = false
        output_size = 0
      end

      return {
        :num => case_num,
        :msg => results[0],
        :run_stat => run_stat,
        :output => output_file,
        :output_size => output_size
      }
    end  
  end
  
  # copied from grader/script/lib/test_request_helper.rb
  def extract_running_stat(results)
    running_stat_line = results[-1]
    
    # extract exit status line
    run_stat = ""
    if !(/[Cc]orrect/.match(results[0]))
      run_stat = results[0].chomp
    else
      run_stat = 'Program exited normally'
    end
    
    logger.info "Stat line: #{running_stat_line}"

    # extract running time
    if res = /r(.*)u(.*)s/.match(running_stat_line)
      seconds = (res[1].to_f + res[2].to_f)
      time_stat = "Time used: #{seconds} sec."
    else
      seconds = nil
      time_stat = "Time used: n/a sec."
    end
    
    # extract memory usage
    if res = /s(.*)m/.match(running_stat_line)
      memory_used = res[1].to_i
    else
      memory_used = -1
    end
    
    return {
      :msg => "#{run_stat}\n#{time_stat}",
      :running_time => seconds,
      :exit_status => run_stat,
      :memory_usage => memory_used
    }
  end

  def confirm_and_update_start_time
    user = User.find(session[:user_id])
    if (GraderConfiguration.indv_contest_mode? and 
        GraderConfiguration['contest.confirm_indv_contest_start'] and
        !user.contest_started?)
      redirect_to :action => 'confirm_contest_start' and return
    end
    if not GraderConfiguration.analysis_mode?
      user.update_start_time
    end
  end

  def reject_announcement_refresh_when_logged_out
    if not session[:user_id]
      render :text => 'Access forbidden', :status => 403
    end

    if GraderConfiguration.multicontests?
      user = User.find(session[:user_id])
      if user.contest_stat.forced_logout
        render :text => 'Access forbidden', :status => 403
      end
    end
  end

end

