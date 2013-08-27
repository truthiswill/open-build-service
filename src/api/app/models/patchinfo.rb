# a Patchinfo lives in a Project, but is not a package - it represents a special file
# in a update package

# if you wonder it's not a module, read http://blog.codeclimate.com/blog/2012/11/14/why-ruby-class-methods-resist-refactoring
class Patchinfo

  def logger
    Rails.logger
  end

  class ReleasetargetNotFound < APIException
    setup 404
  end

  def is_repository_matching?(repo, rt)
    return false if repo.project.name != rt['project']
    if rt['repository']
      return false if repo.name != rt['repository']
    end
    return true
  end

  # check if we caa find the releasetarget (xmlhash) in the project
  def check_releasetarget!(rt)
    @project.repositories.each do |r|
      r.release_targets.each do |prt|
        return if is_repository_matching?(prt.target_repository, rt)
      end
    end
    raise ReleasetargetNotFound.new "Release target '#{rt['project']}/#{rt['repository']}' is not defined in this project '#{@project.name}'"
  end

  def verify_data(project, raw_post)
    @project = project
    data = Xmlhash.parse(raw_post)
    # check the packager field
    User.get_by_login data["packager"] if data["packager"]
    # are releasetargets specified ? validate that this project is actually defining them.
    data.elements("releasetarget") { |r| check_releasetarget!(r) }
  end

  def add_issue_to_patchinfo(issue)
    tracker = issue.issue_tracker
    return if @patchinfo.has_element?("issue[(@id='#{issue.name}' and @tracker='#{tracker.name}')]")
    e = @patchinfo.add_element "issue"
    e.set_attribute "tracker", tracker.name
    e.set_attribute "id", issue.name
    @patchinfo.category.text = "security" if tracker.kind == "cve"
  end

  def fetch_issue_for_package(package)
    # create diff per package
    return if package.package_kinds.find_by_kind 'patchinfo'

    package.package_issues.each do |i|
      add_issue_to_patchinfo(i.issue) if i.change == "added"
    end
  end

  def update_patchinfo(project, patchinfo, opts = {})
    project.check_write_access!
    @patchinfo = patchinfo

    opts[:enfore_issue_update] ||= false

    # collect bugnumbers from diff
    project.packages.each { |p| fetch_issue_for_package(p) }

    # update informations of empty issues
    patchinfo.each_issue do |i|
      next if !i.text.blank? or i.name.blank?
      issue = Issue.find_or_create_by_name_and_tracker(i.name, i.tracker)
      next unless issue
      # enforce update from issue server
      issue.fetch_updates if opts[:enfore_issue_update]
      i.text = issue.summary
    end

    return patchinfo
  end

  def patchinfo_axml(project)
    xml = ActiveXML::Node.new("<patchinfo/>")
    if project.is_maintenance_incident?
      # this is a maintenance incident project, the sub project name is the maintenance ID
      xml.set_attribute('incident', @pkg.project.name.gsub(/.*:/, ''))
    end
    xml.add_element("category").text = "recommended"
    xml.add_element("rating").text ="low"
    xml
  end

  def create_patchinfo_from_request(project, req)
    project.check_write_access!
    @prj = project

    # create patchinfo package
    create_patchinfo_package("patchinfo")

    # create patchinfo XML file
    xml = patchinfo_axml(project)

    description = req.description || ''
    xml.add_element('packager').text = req.creator
    xml.add_element("summary").text = description.split(/\n|\r\n/)[0] # first line only
    xml.add_element("description").text = description

    xml = self.update_patchinfo(project, xml, enfore_issue_update: true)
    Suse::Backend.put(patchinfo_url(@pkg, "generated by request id #{req.id} accept call"), xml.dump_xml)
    @pkg.sources_changed
  end

  class PatchinfoFileExists < APIException;
  end
  class PackageAlreadyExists < APIException;
  end

  def create_patchinfo_package(pkg_name)
    Package.transaction do
      @pkg = @prj.packages.create(name: pkg_name, title: "Patchinfo", description: "Collected packages for update")
      @pkg.add_flag("build", "enable", nil, nil)
      @pkg.add_flag("publish", "enable", nil, nil) unless @prj.flags.find_by_flag_and_status("access", "disable")
      @pkg.add_flag("useforbuild", "disable", nil, nil)
      @pkg.store
    end
  end

  def require_package_for_patchinfo(project, pkg_name, force)
    pkg_name ||= "patchinfo"
    valid_package_name! pkg_name

    # create patchinfo package
    unless Package.exists_by_project_and_name(project, pkg_name)
      @prj = Project.get_by_name(project)
      create_patchinfo_package(pkg_name)
      return
    end

    @pkg = Package.get_by_project_and_name project, pkg_name
    return if force
    if @pkg.package_kinds.find_by_kind 'patchinfo'
      raise PatchinfoFileExists.new "createpatchinfo command: the patchinfo #{pkg_name} exists already. " +
                                        "Either use force=1 re-create the _patchinfo or use updatepatchinfo for updating."
    else
      raise PackageAlreadyExists.new "createpatchinfo command: the package #{pkg_name} exists already, " +
                                         "but is  no patchinfo. Please create a new package instead."
    end

  end

  def create_patchinfo(project, pkg_name, opts = {})
    require_package_for_patchinfo(project, pkg_name, opts[:force])

    # create patchinfo XML file
    xml = patchinfo_axml(@pkg.project)
    xml.add_element('packager').text = User.current.login
    xml.add_element("summary").text = opts[:comment]
    xml.add_element("description")
    xml = self.update_patchinfo(@pkg.project, xml)
    Suse::Backend.put(patchinfo_url(@pkg, "generated by createpatchinfo call"), xml.dump_xml)
    @pkg.sources_changed
    return { :targetproject => @pkg.project.name, :targetpackage => @pkg.name }
  end

  def patchinfo_url(pkg, comment)
    p = { user: User.current.login, comment: comment }
    path = pkg.source_path("_patchinfo")
    path << Suse::Backend.build_query_from_hash(p, [:user, :comment])
  end

  def cmd_update_patchinfo(project, package)
    pkg = Package.get_by_project_and_name project, package

    # get existing file
    xml = read_patchinfo_axml(pkg)
    xml = self.update_patchinfo(pkg.project, xml)

    Suse::Backend.put(patchinfo_url(pkg, "updated via updatepatchinfo call"), xml.dump_xml)
    pkg.sources_changed
  end

  def read_patchinfo_axml(pkg)
    ActiveXML::Node.new(pkg.source_file("_patchinfo"))
  end

  def read_patchinfo_xmlhash(pkg)
    Xmlhash.parse(pkg.source_file("_patchinfo"))
  end

  class IncompletePatchinfo < APIException;
  end

  def fetch_release_targets(pkg)
    data = read_patchinfo_xmlhash(pkg)
    # validate _patchinfo for completeness
    if data.empty?
      raise IncompletePatchinfo.new "The _patchinfo file is not parseble"
    end
    %w(rating category summary).each do |field|
      if data[field].blank?
        raise IncompletePatchinfo.new "The _patchinfo has no #{field} set"
      end
    end
    # a patchinfo may limit the targets
    data.elements("releasetarget")
  end

end
