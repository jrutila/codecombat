RootView = require 'views/core/RootView'
template = require 'templates/courses/teacher-class-view'
helper = require 'lib/coursesHelper'
ClassroomSettingsModal = require 'views/courses/ClassroomSettingsModal'
InviteToClassroomModal = require 'views/courses/InviteToClassroomModal'
ActivateLicensesModal = require 'views/courses/ActivateLicensesModal'
RemoveStudentModal = require 'views/courses/RemoveStudentModal'

Classroom = require 'models/Classroom'
Classrooms = require 'collections/Classrooms'
LevelSessions = require 'collections/LevelSessions'
User = require 'models/User'
Users = require 'collections/Users'
Course = require 'models/Course'
Courses = require 'collections/Courses'
CourseInstance = require 'models/CourseInstance'
CourseInstances = require 'collections/CourseInstances'
Campaigns = require 'collections/Campaigns'

module.exports = class TeacherClassView extends RootView
  id: 'teacher-class-view'
  template: template
  
  events:
    'click .students-tab-btn': (e) ->
      e.preventDefault()
      @trigger 'open-students-tab'
    'click .course-progress-tab-btn': (e) ->
      e.preventDefault()
      @trigger 'open-course-progress-tab'
    'click .edit-classroom': 'onClickEditClassroom'
    'click .add-students-btn': 'onClickAddStudents'
    # 'click .sort-by-name': 'sortByName'
    'click .sort-by-name': -> @trigger 'students:sort-by-name'
    'click .sort-by-progress': 'sortByProgress'
    'click #copy-url-btn': 'copyURL'
    'click #copy-code-btn': 'copyCode'
    'click .remove-student-link': 'onClickRemoveStudentLink'
    'click .assign-student-button': 'onClickAssign'
    'click .enroll-student-button': 'onClickEnroll'
    'click .assign-to-selected-students': 'onClickBulkAssign'
    'click .enroll-selected-students': 'onClickBulkEnroll'
    'click .select-all': 'onClickSelectAll'
    'click .student-checkbox': 'onClickStudentCheckbox'
    'change .course-select': (e) ->
      @trigger 'course-select:change', { selectedCourse: @courses.get($(e.currentTarget).val()) }
      
  # TODO: Move into CocoView
  state: {}
  setState: (newState) ->
    # TODO: Defer state changes once we remove renders from elsewhere
    _.assign @state, newState
    @render()
    
  getInitialState: ->
    if Backbone.history.getHash() in ['students-tab', 'course-progress-tab']
      activeTab = '#' + Backbone.history.getHash()
    else
      activeTab = '#students-tab'
    {
      sortAttribute: 'name'
      sortDirection: 1
      activeTab
      students: new Users()
      classCode: ""
      joinURL: ""
      errors:
        assigningToNobody: false
        assigningToUnenrolled: false
      selectedCourse: new Course() # For both bulk-assign and Course Progress
      classStats:
        averagePlaytime: ""
        totalPlaytime: ""
        averageLevelsComplete: ""
        totalLevelsComplete: ""
        enrolledUsers: ""
    }
    # TODO: use these values instead of instanve variables

  initialize: (options, classroomID) ->
    super(options)
    @state = @getInitialState() # TODO: Move into CocoView?
    @progressDotTemplate = require 'templates/courses/progress-dot'
    
    window.location.hash = @state.activeTab # TODO: Don't push to URL history (maybe don't use url fragment for default tab)

    @sortAttribute = 'name'
    @sortDirection = 1
    
    @classroom = new Classroom({ _id: classroomID })
    @classroom.fetch()
    @supermodel.trackModel(@classroom)
    
    @students = new Users()
    @listenTo @classroom, 'sync', ->
      jqxhrs = @students.fetchForClassroom(@classroom, removeDeleted: true)
      if jqxhrs.length > 0
        @supermodel.trackCollection(@students)
      
      @classroom.sessions = new LevelSessions()
      requests = @classroom.sessions.fetchForAllClassroomMembers(@classroom)
      @supermodel.trackRequests(requests)
      
    @courses = new Courses()
    @courses.fetch()
    @supermodel.trackCollection(@courses)
    
    @campaigns = new Campaigns()
    @campaigns.fetchByType('course')
    @supermodel.trackCollection(@campaigns)
    
    @courseInstances = new CourseInstances()
    @courseInstances.fetchByOwner(me.id)
    @supermodel.trackCollection(@courseInstances)
    
    @attachMediatorEvents()
      
  attachMediatorEvents: () ->
    # Model/Collection events
    @listenTo @classroom, 'sync change update', ->
      classCode = @classroom.get('codeCamel') or @classroom.get('code')
      @setState {
        classCode: classCode
        joinURL: document.location.origin + "/courses?_cc=" + classCode
      }
    @listenTo @courses, 'sync change update', ->
      @setCourseMembers() # Is this necessary?
      @setState selectedCourse: @courses.first() unless @state.selectedCourse
    @listenTo @courseInstances, 'sync change update', ->
      @setCourseMembers()
    @listenToOnce @students, 'sync', # TODO: This seems like it's in the wrong place?
      @sortByName
    @listenTo @students, 'sync change update', ->
      # Set state/props of things that depend on students?
      # Set specific parts of state based on the models, rather than just dumping the collection there?
      classStats = @calculateClassStats()
      @setState classStats: classStats if classStats
      @setState students: @students
    @listenTo @students, 'sort', ->
      @setState students: @students
    
    # DOM events
    @listenTo @, 'students:sort-by-name', @sortByName # or something
    @listenTo @, 'open-students-tab', ->
      if window.location.hash isnt '#students-tab'
        window.location.hash = '#students-tab'
      @setState activeTab: '#students-tab'
    @listenTo @, 'open-course-progress-tab', ->
      if window.location.hash isnt '#course-progress-tab'
        window.location.hash = '#course-progress-tab'
      @setState activeTab: '#course-progress-tab'
    @listenTo @, 'course-select:change', ({ selectedCourse }) ->
      @setState selectedCourse: selectedCourse

  setCourseMembers: =>
    for course in @courses.models
      course.instance = @courseInstances.findWhere({ courseID: course.id, classroomID: @classroom.id })
      course.members = course.instance?.get('members') or []
    null
    
  onLoaded: ->
    @removeDeletedStudents() # TODO: Move this to mediator listeners? For both classroom and students?
    
    # TODO: How to structure this in @state?
    for student in @students.models
      # TODO: this is a weird hack
      studentsStub = new Users([ student ])
      student.latestCompleteLevel = helper.calculateLatestComplete(@classroom, @courses, @campaigns, @courseInstances, studentsStub)
    
    earliestIncompleteLevel = helper.calculateEarliestIncomplete(@classroom, @courses, @campaigns, @courseInstances, @students)
    latestCompleteLevel = helper.calculateLatestComplete(@classroom, @courses, @campaigns, @courseInstances, @students)
      
    classroomsStub = new Classrooms([ @classroom ])
    progressData = helper.calculateAllProgress(classroomsStub, @courses, @campaigns, @courseInstances, @students)
    # conceptData: helper.calculateConceptsCovered(classroomsStub, @courses, @campaigns, @courseInstances, @students)
    
    @setState {
      earliestIncompleteLevel
      latestCompleteLevel
      progressData
      classStats: @calculateClassStats()
      selectedCourse: @courses.first()
    }
    super()
  
  copyCode: ->
    @$('#join-code-input').val(@classCode).select()
    @tryCopy()
  
  copyURL: ->
    @$('#join-url-input').val(@joinURL).select()
    @tryCopy()
    
  tryCopy: ->
    try
      document.execCommand('copy')
      application.tracker?.trackEvent 'Classroom copy URL', category: 'Courses', classroomID: @classroom.id, url: @joinURL
    catch err
      message = 'Oops, unable to copy'
      noty text: message, layout: 'topCenter', type: 'error', killer: false
    
  onClickEditClassroom: (e) ->
    classroom = @classroom
    modal = new ClassroomSettingsModal({ classroom: classroom })
    @openModalView(modal)
    @listenToOnce modal, 'hide', @render
  
  onClickRemoveStudentLink: (e) ->
    user = @students.get($(e.currentTarget).data('student-id'))
    modal = new RemoveStudentModal({
      classroom: @classroom
      user: user
      courseInstances: @courseInstances
    })
    @openModalView(modal)
    modal.once 'remove-student', @onStudentRemoved, @

  onStudentRemoved: (e) ->
    @students.remove(e.user)
    application.tracker?.trackEvent 'Classroom removed student', category: 'Courses', classroomID: @classroom.id, userID: e.user.id

  onClickAddStudents: (e) =>
    modal = new InviteToClassroomModal({ classroom: @classroom })
    @openModalView(modal)
    @listenToOnce modal, 'hide', @render
  
  removeDeletedStudents: () ->
    _.remove(@classroom.get('members'), (memberID) =>
      not @students.get(memberID) or @students.get(memberID)?.get('deleted')
    )
    true
    
  sortByName: (e) ->
    if @sortValue is 'name'
      @sortDirection = -@sortDirection
    else
      @sortValue = 'name'
      @sortDirection = 1
      
    dir = @sortDirection
    @students.comparator = (student1, student2) ->
      return (if student1.broadName().toLowerCase() < student2.broadName().toLowerCase() then -dir else dir)
    @students.sort()
    
  sortByProgress: (e) ->
    if @sortValue is 'progress'
      @sortDirection = -@sortDirection
    else
      @sortValue = 'progress'
      @sortDirection = 1
      
    dir = @sortDirection
    
    @students.comparator = (student) ->
      #TODO: I would like for this to be in the Level model,
      #      but it doesn't know about its own courseNumber
      level = student.latestCompleteLevel
      if not level
        return -dir
      return dir * ((1000 * level.courseNumber) + level.levelNumber)
    @students.sort()
  
  getSelectedStudentIDs: ->
    @$('.student-row .checkbox-flat input:checked').map (index, checkbox) ->
      $(checkbox).data('student-id')
    
  ensureInstance: (courseID) ->
    
  onClickEnroll: (e) ->
    userID = $(e.currentTarget).data('user-id')
    user = @students.get(userID)
    selectedUsers = new Users([user])
    modal = new ActivateLicensesModal { @classroom, selectedUsers, users: @students }
    @openModalView(modal)
    modal.once 'redeem-users', -> document.location.reload()
    application.tracker?.trackEvent 'Classroom started enroll students', category: 'Courses'
  
  onClickBulkEnroll: ->
    courseID = @$('.bulk-course-select').val()
    courseInstance = @courseInstances.findWhere({ courseID, classroomID: @classroom.id })
    userIDs = @getSelectedStudentIDs().toArray()
    selectedUsers = new Users(@students.get(userID) for userID in userIDs)
    modal = new ActivateLicensesModal { @classroom, selectedUsers, users: @students }
    @openModalView(modal)
    modal.once 'redeem-users', -> document.location.reload()
    application.tracker?.trackEvent 'Classroom started enroll students', category: 'Courses'
    
  onClickAssign: (e) ->
    userID = $(e.currentTarget).data('user-id')
    user = @students.get(userID)
    members = [userID]
    courseID = $(e.currentTarget).data('course-id')
    
    @assignCourse courseID, members
    
  onClickBulkAssign: ->
    courseID = @$('.bulk-course-select').val()
    selectedIDs = @getSelectedStudentIDs()
    members = selectedIDs.filter((index, userID) =>
      user = @students.get(userID)
      user.isEnrolled()
    ).toArray()
    
    assigningToUnenrolled = _.any selectedIDs, (userID) =>
      not @students.get(userID).isEnrolled()
      
    assigningToNobody = selectedIDs.length is 0
    
    @setState errors: { assigningToNobody, assigningToUnenrolled }
    
    @assignCourse(courseID, members, @onBulkAssignSuccess)
    
  # TODO: Move this to the model. Use promises/callbacks?
  assignCourse: (courseID, members) ->
    courseInstance = @courseInstances.findWhere({ courseID, classroomID: @classroom.id })
    if courseInstance
      courseInstance.addMembers members
    else
      courseInstance = new CourseInstance {
        courseID,
        classroomID: @classroom.id
        ownerID: @classroom.get('ownerID')
        aceConfig: {}
      }
      @courseInstances.add(courseInstance)
      courseInstance.save {}, {
        success: ->
          courseInstance.addMembers members
      }
    null
    
  onBulkAssignSuccess: =>
    @render() unless @destroyed
    noty text: $.i18n.t('teacher.assigned'), layout: 'center', type: 'information', killer: true, timeout: 5000
    
  onClickSelectAll: (e) ->
    e.preventDefault()
    checkboxes = @$('.student-checkbox input')
    if _.all(checkboxes, 'checked')
      @$('.select-all input').prop('checked', false)
      checkboxes.prop('checked', false)
    else
      @$('.select-all input').prop('checked', true)
      checkboxes.prop('checked', true)
    null
    
  onClickStudentCheckbox: (e) ->
    e.preventDefault()
    # $(e.target).$()
    checkbox = $(e.currentTarget).find('input')
    checkbox.prop('checked', not checkbox.prop('checked'))
    # checkboxes.prop('checked', false)
    checkboxes = @$('.student-checkbox input')
    @$('.select-all input').prop('checked', _.all(checkboxes, 'checked'))

  calculateClassStats: ->
    return unless @classroom.sessions?.loaded and @students.loaded
    stats = {}

    playtime = 0
    total = 0
    for session in @classroom.sessions.models
      pt = session.get('playtime') or 0
      playtime += pt
      total += 1
    stats.averagePlaytime = if playtime and total then moment.duration(playtime / total, "seconds").humanize() else 0
    stats.totalPlaytime = if playtime then moment.duration(playtime, "seconds").humanize() else 0
    # TODO: Humanize differently ('1 hour' instead of 'an hour')

    completeSessions = @classroom.sessions.filter (s) -> s.get('state')?.complete
    stats.averageLevelsComplete = if @students.size() then (_.size(completeSessions) / @students.size()).toFixed(1) else 'N/A'  # '
    stats.totalLevelsComplete = _.size(completeSessions)

    enrolledUsers = @students.filter (user) -> user.get('coursePrepaidID')
    stats.enrolledUsers = _.size(enrolledUsers)
    
    return stats
