<%@ page session="false" contentType="text/plain; charset=UTF-8" %><%
    // Old /guacamole bookmarks and the bare server address: same path under /betterguac
    String path = request.getServletPath();
    if (request.getPathInfo() != null) path += request.getPathInfo();
    if (path.equals("/redirect.jsp")) path = "/";
    String query = request.getQueryString();
    response.sendRedirect("/betterguac" + path + (query != null ? "?" + query : ""));
%>
